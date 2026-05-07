#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"
require_relative "fixture_readiness_lib"

def usage_error(message)
  warn "fixture readiness usage error: #{message}"
  exit 2
end

options = {
  root: StrictModeFixtures.project_root,
  provider: "all",
  provider_versions: {}
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--provider-version PROVIDER=VERSION") do |value|
      provider, version = StrictModeFixtureReadiness.parse_provider_version_assignment(value)
      options[:provider_versions][provider] = version
    end
  end.parse!(ARGV)
rescue OptionParser::ParseError, ArgumentError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

begin
  providers = StrictModeFixtures.provider_list(options[:provider])
  StrictModeFixtureReadiness.validate_provider_versions!(options[:provider_versions], providers)
rescue ArgumentError => e
  usage_error(e.message)
end

begin
  errors = StrictModeFixtureReadiness.enforcing_errors(options[:root], providers, options[:provider_versions])
rescue RuntimeError, ArgumentError => e
  warn "fixture readiness failed: #{e.message}"
  exit 1
end

if errors.empty?
  puts "fixture readiness passed"
  exit 0
end

errors.each { |error| warn error }
exit 1
