# typed: strict
# frozen_string_literal: true

require "docker_registry2"
require "sorbet-runtime"
require "dependabot/powershell/package/package_details_fetcher"

module Dependabot
  module Powershell
    module Package
      class PackageDetailsFetcher
        class MarRegistry < DockerRegistry2::Registry
          extend T::Sig

          class InvalidManifest < DockerRegistry2::Exception; end
          class InvalidMetadata < DockerRegistry2::Exception; end

          sig { params(error: DockerRegistry2::RegistryHTTPException).returns(Integer) }
          def self.http_status(error)
            if error.respond_to?(:status)
              status = error.method(:status).call
              return status if status.is_a?(Integer)
            end

            status = error.message[/status (\d+)/, 1]
            return status.to_i if status

            raise error
          end

          sig do
            params(manifest: T::Hash[String, T.anything]).returns(T::Hash[String, T.anything])
          end
          def self.manifest_metadata(manifest)
            layers = manifest["layers"]
            layer = layers.first if layers.is_a?(Array)
            annotations = layer["annotations"] if layer.is_a?(Hash)
            metadata_json = annotations["metadata"] if annotations.is_a?(Hash)
            raise InvalidMetadata unless metadata_json.is_a?(String)

            metadata = JSON.parse(metadata_json)
            raise InvalidMetadata unless metadata.is_a?(Hash)

            metadata
          rescue JSON::ParserError
            raise InvalidMetadata
          end

          sig { params(repository: String, tag: String).returns(T::Hash[String, T.anything]) }
          def manifest(repository, tag)
            super
          rescue ArgumentError
            raise InvalidManifest
          end

          private

          sig { params(header: String).returns(T.nilable(String)) }
          def authenticate_bearer(header)
            super
          rescue DockerRegistry2::NotFound
            raise DockerRegistry2::RegistryAuthenticationException
          end
        end
      end
    end
  end
end
