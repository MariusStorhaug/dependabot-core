# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "dependabot/credential"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/pull_request_creator"
require "dependabot/source"

module Dependabot
  module DryRun
    class PullRequestMode
      extend T::Sig

      AUTHOR_DETAILS = T.let(
        {
          name: "dependabot[bot]",
          email: "49699333+dependabot[bot]@users.noreply.github.com"
        }.freeze,
        T::Hash[Symbol, String]
      )

      sig do
        params(
          source: Dependabot::Source,
          credentials: T::Array[Dependabot::Credential],
          dependency_names: T.nilable(T::Array[String]),
          cache_steps: T::Array[String]
        ).void
      end
      def initialize(source:, credentials:, dependency_names:, cache_steps:)
        @source = source
        @credentials = credentials
        @dependency_names = dependency_names
        @cache_steps = cache_steps
        @created = T.let(false, T::Boolean)
      end

      sig { void }
      def validate!
        unless source.provider == "github"
          raise ArgumentError, "--create-pull-request supports only the github provider"
        end
        unless dependency_names&.one?
          raise ArgumentError, "--create-pull-request requires exactly one dependency through --dep"
        end
        raise ArgumentError, "--create-pull-request cannot be combined with --cache" if cache_steps.any?
        return if source_credential?

        raise ArgumentError,
              "--create-pull-request requires a git_source credential for #{source.hostname}"
      end

      sig { params(dependencies: T::Array[Dependabot::Dependency]).void }
      def validate_dependency_selection!(dependencies)
        return if dependencies.one?

        raise ArgumentError,
              "--create-pull-request requires exactly one matching parsed dependency"
      end

      sig { params(files: T::Array[Dependabot::DependencyFile]).void }
      def validate_dependency_files!(files)
        return if files.any?

        raise "--create-pull-request requires fetched dependency files"
      end

      sig { returns(T::Boolean) }
      def created?
        @created
      end

      sig do
        params(
          base_commit: T.nilable(String),
          dependencies: T::Array[Dependabot::Dependency],
          files: T::Array[Dependabot::DependencyFile],
          message: Dependabot::PullRequestCreator::Message,
          commit_message_options: T::Hash[Symbol, T.anything]
        ).returns(T.anything)
      end
      def create(base_commit:, dependencies:, files:, message:, commit_message_options:)
        validate!
        raise ArgumentError, "--create-pull-request creates at most one pull request" if created?
        raise ArgumentError, "--create-pull-request requires a resolved base commit" if base_commit.to_s.empty?

        pull_request = Dependabot::PullRequestCreator.new(
          source: source,
          base_commit: T.must(base_commit),
          dependencies: dependencies,
          files: files,
          credentials: credentials,
          message: message,
          commit_message_options: commit_message_options,
          author_details: AUTHOR_DETAILS,
          label_language: true,
          require_up_to_date_base: true
        ).create

        raise "Pull request creation did not return a pull request" unless pull_request

        @created = true
        pull_request
      end

      private

      sig { returns(Dependabot::Source) }
      attr_reader :source

      sig { returns(T::Array[Dependabot::Credential]) }
      attr_reader :credentials

      sig { returns(T.nilable(T::Array[String])) }
      attr_reader :dependency_names

      sig { returns(T::Array[String]) }
      attr_reader :cache_steps

      sig { returns(T::Boolean) }
      def source_credential?
        credentials.any? do |credential|
          credential["type"] == "git_source" &&
            credential_matches_source?(credential) &&
            credential_has_secret?(credential)
        end
      end

      sig { params(credential: Dependabot::Credential).returns(T::Boolean) }
      def credential_matches_source?(credential)
        return credential["region"] == source.hostname if source.provider == "codecommit"

        credential["host"] == source.hostname
      end

      sig { params(credential: Dependabot::Credential).returns(T::Boolean) }
      def credential_has_secret?(credential)
        [credential["password"], credential["token"]].compact.any? do |secret|
          !secret.strip.empty?
        end
      end
    end
  end
end
