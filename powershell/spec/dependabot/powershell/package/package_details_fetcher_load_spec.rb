# typed: false
# frozen_string_literal: true

require "open3"
require "spec_helper"
require "dependabot/powershell/package/package_details_fetcher"

RSpec.describe Dependabot::Powershell::Package::PackageDetailsFetcher do
  it "supports loading the MAR registry directly" do
    code = 'require "dependabot/powershell/package/package_details_fetcher/mar_registry"'
    _stdout, stderr, status = Open3.capture3(Gem.ruby, "-Ilib", "-e", code)

    expect(status).to be_success, stderr
  end
end
