# typed: strict
# frozen_string_literal: true

require "json"
require "uri"
require "docker_registry2"
require "sorbet-runtime"

require "dependabot/errors"
require "dependabot/powershell"
require "dependabot/powershell/version"
require "dependabot/package/package_release"
require "dependabot/package/package_details"

module Dependabot
  module Powershell
    module Package
      # Fetches the full set of published versions for a PowerShell module from
      # Microsoft's trusted artifact registry, falling back to the PowerShell
      # Gallery when the module is not published there.
      #
      # The gallery exposes a NuGet v2 (OData/Atom) feed. `FindPackagesById()`
      # returns every version ever published for a module name, paginated via
      # `<link rel="next">` entries, so we must page through the whole feed
      # (up to a safety cap) to make a robust, client-side latest-version
      # selection rather than trusting the feed's `IsLatestVersion` /
      # `IsAbsoluteLatestVersion` flags (which reflect only the gallery's own
      # notion of "latest", not what Dependabot's ignore/cooldown rules allow).
      class PackageDetailsFetcher
        extend T::Sig

        require_relative "package_details_fetcher/mar_registry"
        require_relative "package_details_fetcher/powershell_gallery_fetcher"

        class InvalidMarResponse < StandardError; end
        class InvalidMarPagination < InvalidMarResponse; end

        PSGALLERY_API_BASE = "https://www.powershellgallery.com/api/v2"
        MAR_API_BASE = "https://mcr.microsoft.com"
        MAR_REPOSITORY_PREFIX = "psresource/"
        MAR_OPEN_TIMEOUT_IN_SECONDS = 2
        MAR_READ_TIMEOUT_IN_SECONDS = 60
        MAR_SOURCE = T.let(
          { type: "registry", url: MAR_API_BASE }.freeze,
          T::Hash[Symbol, String]
        )
        PSGALLERY_SOURCE = T.let(
          { type: "registry", url: PSGALLERY_API_BASE }.freeze,
          T::Hash[Symbol, String]
        )

        # Defends against pathological/looping feeds. In practice even the
        # most prolific PowerShell Gallery modules have far fewer than this
        # many published versions.
        MAX_PAGES = 25

        # The gallery uses a sentinel `Published` date of 1900-01-01 to mark
        # package versions that have been unlisted (delisted) by their owner,
        # following the same convention as the NuGet gallery it is built on.
        UNLISTED_PUBLISHED_DATE = "1900-01-01T00:00:00"
        PSGALLERY_WEB_BASE = "https://www.powershellgallery.com"
        MANIFEST_GUID_PATTERN = /
          ['"]?GUID['"]?\s*\\?=\s*['"]
          (?<guid>[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})
          ['"]
        /ix
        GUID_PATTERN = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i

        sig { params(dependency: Dependabot::Dependency).void }
        def initialize(dependency:)
          @dependency = dependency
          @registry_source = T.let(nil, T.nilable(Symbol))
          @powershell_gallery_fetcher = T.let(nil, T.nilable(PowershellGalleryFetcher))
        end

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        sig { returns(T::Boolean) }
        def mar_source?
          @registry_source == :mar
        end

        sig { returns(T.nilable(T::Hash[Symbol, String])) }
        def selected_source
          return MAR_SOURCE if @registry_source == :mar
          return PSGALLERY_SOURCE if @registry_source == :psgallery

          nil
        end

        sig { returns(Dependabot::Package::PackageDetails) }
        def fetch
          Dependabot::Package::PackageDetails.new(
            dependency: dependency,
            releases: fetch_package_releases
          )
        end

        sig { params(version: String).returns(String) }
        def manifest_guid_for(version)
          return mar_manifest_guid_for(version) if @registry_source == :mar

          powershell_gallery_fetcher.manifest_guid_for(version)
        end

        sig { returns(T::Array[Dependabot::Package::PackageRelease]) }
        def fetch_package_releases
          mar_releases = fetch_mar_package_releases
          unless mar_releases.nil?
            @registry_source = :mar
            return mar_releases
          end

          @registry_source = :psgallery
          powershell_gallery_fetcher.fetch_releases
        end

        private

        sig { returns(T.nilable(T::Array[Dependabot::Package::PackageRelease])) }
        def fetch_mar_package_releases
          Dependabot.logger.info("Fetching package (Microsoft Artifact Registry) info for #{dependency.name}")
          tags = fetch_mar_tags
          return nil unless tags

          tags.filter_map do |tag|
            next unless Powershell::Version.correct?(tag)

            Dependabot::Package::PackageRelease.new(
              version: Powershell::Version.new(tag),
              released_at: nil,
              yanked: false,
              package_type: "powershell",
              tag: tag,
              details: { "registry" => "mar" }
            )
          end
        rescue DockerRegistry2::RegistryAuthenticationException,
               DockerRegistry2::RegistryAuthorizationException
          raise Dependabot::PrivateSourceAuthenticationFailure.new(MAR_API_BASE), cause: nil
        rescue DockerRegistry2::RegistryUnknownException
          raise Dependabot::PrivateSourceTimedOut.new(MAR_API_BASE), cause: nil
        rescue DockerRegistry2::RegistrySSLException
          raise Dependabot::PrivateSourceCertificateFailure.new(MAR_API_BASE), cause: nil
        rescue DockerRegistry2::RegistryHTTPException => e
          raise MarRegistry.registry_error(e, dependency.name), cause: nil
        rescue InvalidMarPagination
          message = "Microsoft Artifact Registry response for #{dependency.name} contained invalid pagination data"
          raise Dependabot::DependencyFileNotResolvable.new(message), cause: nil
        rescue JSON::ParserError, InvalidMarResponse
          message = "Microsoft Artifact Registry response for #{dependency.name} was malformed or incomplete"
          raise Dependabot::DependencyFileNotResolvable.new(message), cause: nil
        end

        sig { returns(T.nilable(T::Array[String])) }
        def fetch_mar_tags
          tags = T.let([], T::Array[String])
          next_url = T.let("v2/#{mar_repository_name}/tags/list", T.nilable(String))
          visited_urls = T.let({}, T::Hash[String, T::Boolean])
          first_page = T.let(true, T::Boolean)
          pages = 0

          while next_url
            current_url = prepare_mar_page_url(next_url, visited_urls, pages)
            response = fetch_mar_tags_page(current_url, first_page:)
            return nil unless response

            tags.concat(mar_tags_from(response))
            next_url = mar_next_page_url(response)
            first_page = false
            pages += 1
          end

          tags.uniq
        end

        sig do
          params(
            next_url: String,
            visited_urls: T::Hash[String, T::Boolean],
            pages: Integer
          ).returns(String)
        end
        def prepare_mar_page_url(next_url, visited_urls, pages)
          raise InvalidMarPagination if pages >= MAX_PAGES

          current_url = URI.join("#{MAR_API_BASE}/", next_url).to_s
          raise InvalidMarPagination if visited_urls[current_url]

          visited_urls[current_url] = true
          current_url
        rescue URI::Error
          raise InvalidMarPagination, cause: nil
        end

        sig do
          params(current_url: String, first_page: T::Boolean).returns(T.nilable(DockerRegistry2::Response))
        end
        def fetch_mar_tags_page(current_url, first_page:)
          docker_registry_client.doget(current_url)
        rescue DockerRegistry2::NotFound
          unless first_page
            message = "Microsoft Artifact Registry returned HTTP 404 for a later tags page for #{dependency.name}"
            raise Dependabot::RegistryError.new(404, message), cause: nil
          end

          Dependabot.logger.info(
            "#{dependency.name} is not available from Microsoft Artifact Registry; " \
            "falling back to PowerShell Gallery"
          )
          nil
        end

        sig { params(response: DockerRegistry2::Response).returns(T::Array[String]) }
        def mar_tags_from(response)
          page = JSON.parse(response.body)
          raise InvalidMarResponse, "Invalid tags response for #{dependency.name}" unless page.is_a?(Hash)

          page_tags = page["tags"]
          unless page_tags.is_a?(Array) &&
                 page_tags.all? { |tag| tag.is_a?(String) && tag.valid_encoding? }
            raise InvalidMarResponse, "Invalid tags response for #{dependency.name}"
          end

          page_tags
        end

        sig { params(response: DockerRegistry2::Response).returns(T.nilable(String)) }
        def mar_next_page_url(response)
          link = response.headers[:link]
          return unless link
          raise InvalidMarPagination unless link.is_a?(String) && link.valid_encoding?

          match = link.match(/<(?<url>[^>]+)>\s*;\s*rel="?next"?/i)
          raise InvalidMarPagination unless match

          next_url = MarRegistry.resolve_tags_page_url(response.request_url, T.must(match[:url]), mar_repository_name)
          raise InvalidMarPagination unless next_url

          next_url
        end

        sig { params(version: String).returns(String) }
        def mar_manifest_guid_for(version)
          manifest = docker_registry_client.manifest(mar_repository_name, version)
          metadata = MarRegistry.manifest_metadata(manifest)
          guid = metadata["GUID"] if metadata.is_a?(Hash)
          return guid if guid.is_a?(String) && guid.valid_encoding? && guid.match?(GUID_PATTERN)

          raise Dependabot::DependencyFileNotResolvable,
                "Microsoft Artifact Registry manifest for #{dependency.name} #{version} did not contain a valid GUID"
        rescue DockerRegistry2::RegistryAuthenticationException,
               DockerRegistry2::RegistryAuthorizationException
          raise Dependabot::PrivateSourceAuthenticationFailure.new(MAR_API_BASE), cause: nil
        rescue DockerRegistry2::RegistryUnknownException
          raise Dependabot::PrivateSourceTimedOut.new(MAR_API_BASE), cause: nil
        rescue DockerRegistry2::RegistrySSLException
          raise Dependabot::PrivateSourceCertificateFailure.new(MAR_API_BASE), cause: nil
        rescue DockerRegistry2::NotFound
          message = "Microsoft Artifact Registry returned HTTP 404 for #{dependency.name} #{version} manifest"
          raise Dependabot::RegistryError.new(404, message), cause: nil
        rescue DockerRegistry2::RegistryHTTPException => e
          raise MarRegistry.registry_error(e, dependency.name), cause: nil
        rescue MarRegistry::InvalidManifest
          raise(
            Dependabot::DependencyFileNotResolvable.new(
              "Microsoft Artifact Registry response for #{dependency.name} #{version} contained a malformed manifest"
            ),
            cause: nil
          )
        rescue MarRegistry::InvalidMetadata
          raise(
            Dependabot::DependencyFileNotResolvable.new(
              "Microsoft Artifact Registry manifest for #{dependency.name} #{version} contained malformed metadata"
            ),
            cause: nil
          )
        end

        sig { returns(String) }
        def mar_repository_name
          "#{MAR_REPOSITORY_PREFIX}#{dependency.name.downcase}"
        end

        sig { returns(DockerRegistry2::Registry) }
        def docker_registry_client
          @docker_registry_client ||= T.let(
            MarRegistry.new(
              MAR_API_BASE,
              user: nil,
              password: nil,
              open_timeout: MAR_OPEN_TIMEOUT_IN_SECONDS,
              read_timeout: MAR_READ_TIMEOUT_IN_SECONDS,
              http_options: { proxy: ENV.fetch("HTTPS_PROXY", nil) }
            ),
            T.nilable(DockerRegistry2::Registry)
          )
        end

        sig { returns(PowershellGalleryFetcher) }
        def powershell_gallery_fetcher
          @powershell_gallery_fetcher ||= PowershellGalleryFetcher.new(dependency:)
        end
      end
    end
  end
end
