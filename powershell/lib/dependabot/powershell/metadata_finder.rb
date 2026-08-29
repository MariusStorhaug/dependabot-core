# typed: strong
# frozen_string_literal: true

require "uri"
require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"
require "dependabot/powershell/package/package_details_fetcher"

module Dependabot
  module Powershell
    class MetadataFinder < Dependabot::MetadataFinders::Base
      extend T::Sig

      PUBLIC_SOURCE_HOSTS = %w(github.com gitlab.com bitbucket.org dev.azure.com).freeze
      CODECOMMIT_HOST = /\Agit-codecommit\.[a-z0-9-]+\.amazonaws\.com\z/

      private

      sig { override.returns(T.nilable(Dependabot::Source)) }
      def look_up_source
        version = dependency.version
        return unless version

        project_url = package_details_fetcher.project_url_for(version)
        return unless project_url

        project_url = project_url.strip
        return if project_url.empty?
        return unless safe_public_source_url?(project_url)

        Dependabot::Source.from_url(project_url)
      end

      sig { params(url: String).returns(T::Boolean) }
      def safe_public_source_url?(url)
        uri = URI.parse(url)
        return false unless uri.is_a?(URI::HTTP)

        host = uri.host&.downcase
        port = T.cast(uri.port, Integer)
        default_port = T.cast(uri.default_port, Integer)

        !host.nil? &&
          uri.userinfo.nil? &&
          port == default_port &&
          (PUBLIC_SOURCE_HOSTS.include?(host) || CODECOMMIT_HOST.match?(host))
      rescue URI::Error
        false
      end

      sig { returns(Dependabot::Powershell::Package::PackageDetailsFetcher) }
      def package_details_fetcher
        @package_details_fetcher ||= T.let(
          Dependabot::Powershell::Package::PackageDetailsFetcher.new(dependency: dependency),
          T.nilable(Dependabot::Powershell::Package::PackageDetailsFetcher)
        )
      end
    end
  end
end

Dependabot::MetadataFinders.register("powershell", Dependabot::Powershell::MetadataFinder)
