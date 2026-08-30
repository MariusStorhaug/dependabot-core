# typed: false
# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/dependabot/dry_run/pull_request_mode"

RSpec.describe Dependabot::DryRun::PullRequestMode do
  subject(:mode) do
    described_class.new(
      source: source,
      credentials: credentials,
      dependency_names: dependency_names,
      cache_steps: cache_steps
    )
  end

  let(:source) do
    Dependabot::Source.new(
      provider: "github",
      repo: "example/repository",
      directory: "/"
    )
  end
  let(:credentials) do
    [
      Dependabot::Credential.new(
        {
          "type" => "git_source",
          "host" => "github.com",
          "password" => "secret"
        }
      )
    ]
  end
  let(:dependency_names) { ["example"] }
  let(:cache_steps) { [] }

  describe "#validate!" do
    it "accepts one dependency, uncached inputs, and a matching source credential" do
      expect { mode.validate! }.not_to raise_error
    end

    context "without an explicit dependency" do
      let(:dependency_names) { nil }

      it "raises before repository work starts" do
        expect { mode.validate! }
          .to raise_error(ArgumentError, /requires exactly one dependency/)
      end
    end

    context "with multiple explicit dependencies" do
      let(:dependency_names) { %w(first second) }

      it "raises before repository work starts" do
        expect { mode.validate! }
          .to raise_error(ArgumentError, /requires exactly one dependency/)
      end
    end

    context "with cached inputs" do
      let(:cache_steps) { ["files"] }

      it "raises before repository work starts" do
        expect { mode.validate! }
          .to raise_error(ArgumentError, /cannot be combined with --cache/)
      end
    end

    context "without a source credential for the selected host" do
      let(:credentials) do
        [
          Dependabot::Credential.new(
            {
              "type" => "git_source",
              "host" => "github.example.com",
              "password" => "secret"
            }
          )
        ]
      end

      it "raises without exposing credential values" do
        expect { mode.validate! }
          .to raise_error(ArgumentError, /requires a git_source credential for github.com/)
      end
    end

    context "with an empty source credential" do
      let(:credentials) do
        [
          Dependabot::Credential.new(
            {
              "type" => "git_source",
              "host" => "github.com",
              "password" => ""
            }
          )
        ]
      end

      it "raises without exposing credential values" do
        expect { mode.validate! }
          .to raise_error(ArgumentError, /requires a git_source credential for github.com/)
      end
    end
  end

  describe "#create" do
    let(:dependencies) { [instance_double(Dependabot::Dependency)] }
    let(:files) { [instance_double(Dependabot::DependencyFile)] }
    let(:message) { instance_double(Dependabot::PullRequestCreator::Message) }
    let(:pull_request) { instance_double(Sawyer::Resource) }
    let(:creator) { instance_double(Dependabot::PullRequestCreator, create: pull_request) }

    it "delegates one ready pull request to the existing creator with safety enabled" do
      allow(Dependabot::PullRequestCreator).to receive(:new).with(
        source: source,
        base_commit: "base-sha",
        dependencies: dependencies,
        files: files,
        credentials: credentials,
        message: message,
        commit_message_options: { prefix: "deps" },
        author_details: {
          name: "dependabot[bot]",
          email: "49699333+dependabot[bot]@users.noreply.github.com"
        },
        label_language: true,
        require_up_to_date_base: true
      ).and_return(creator)

      result = mode.create(
        base_commit: "base-sha",
        dependencies: dependencies,
        files: files,
        message: message,
        commit_message_options: { prefix: "deps" }
      )

      expect(result).to eq(pull_request)
      expect(creator).to have_received(:create).once
    end

    it "rejects a missing base commit without invoking the creator" do
      expect(Dependabot::PullRequestCreator).not_to receive(:new)

      expect do
        mode.create(
          base_commit: nil,
          dependencies: dependencies,
          files: files,
          message: message,
          commit_message_options: {}
        )
      end.to raise_error(ArgumentError, /requires a resolved base commit/)
    end

    it "rejects a second pull request creation attempt" do
      allow(Dependabot::PullRequestCreator).to receive(:new).and_return(creator)

      2.times do |attempt|
        invocation = lambda do
          mode.create(
            base_commit: "base-sha",
            dependencies: dependencies,
            files: files,
            message: message,
            commit_message_options: {}
          )
        end

        if attempt.zero?
          expect(invocation.call).to eq(pull_request)
        else
          expect(&invocation).to raise_error(ArgumentError, /creates at most one pull request/)
        end
      end

      expect(creator).to have_received(:create).once
    end
  end

  describe "#validate_dependency_selection!" do
    it "accepts one parsed dependency" do
      expect { mode.validate_dependency_selection!([instance_double(Dependabot::Dependency)]) }
        .not_to raise_error
    end

    it "rejects no parsed dependency" do
      expect { mode.validate_dependency_selection!([]) }
        .to raise_error(ArgumentError, /requires exactly one matching parsed dependency/)
    end

    it "rejects multiple parsed dependencies" do
      dependencies = Array.new(2) { instance_double(Dependabot::Dependency) }

      expect { mode.validate_dependency_selection!(dependencies) }
        .to raise_error(ArgumentError, /requires exactly one matching parsed dependency/)
    end
  end

  describe "#validate_dependency_files!" do
    it "accepts fetched dependency files" do
      expect { mode.validate_dependency_files!([instance_double(Dependabot::DependencyFile)]) }
        .not_to raise_error
    end

    it "rejects an empty fetch result" do
      expect { mode.validate_dependency_files!([]) }
        .to raise_error(RuntimeError, /requires fetched dependency files/)
    end
  end
end
