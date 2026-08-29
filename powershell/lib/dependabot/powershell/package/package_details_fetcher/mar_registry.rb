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
