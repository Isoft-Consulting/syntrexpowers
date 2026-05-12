#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require_relative "fixture_readiness_lib"

def usage_error(message)
  warn "enforcement readiness report usage error: #{message}"
  exit 2
end

options = {
  root: StrictModeFixtures.project_root,
  provider: "all",
  format: "text",
  provider_versions: {},
  provider_build_hashes: {}
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--format FORMAT") { |value| options[:format] = value }
    opts.on("--provider-version PROVIDER=VERSION") do |value|
      provider, version = StrictModeFixtureReadiness.parse_provider_version_assignment(value)
      options[:provider_versions][provider] = version
    end
    opts.on("--provider-build-hash PROVIDER=SHA256") do |value|
      provider, build_hash = StrictModeFixtureReadiness.parse_provider_build_hash_assignment(value)
      options[:provider_build_hashes][provider] = build_hash
    end
  end.parse!(ARGV)
rescue OptionParser::ParseError, ArgumentError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
usage_error("--format must be text or json") unless %w[text json].include?(options[:format])

begin
  providers = StrictModeFixtures.provider_list(options[:provider])
  StrictModeFixtureReadiness.validate_provider_versions!(options[:provider_versions], providers)
  StrictModeFixtureReadiness.validate_provider_build_hashes!(options[:provider_build_hashes], providers)
rescue ArgumentError => e
  usage_error(e.message)
end

begin
  report = StrictModeFixtureReadiness.enforcing_report(options[:root], providers, options[:provider_versions], options[:provider_build_hashes])
rescue RuntimeError, ArgumentError => e
  warn "enforcement readiness report failed: #{e.message}"
  exit 1
end

if options[:format] == "json"
  puts JSON.pretty_generate(report)
else
  puts "enforcing readiness: #{report.fetch("ready") ? "ready" : "not-ready"}"
  report.fetch("providers").each do |provider_report|
    puts "#{provider_report.fetch("provider")}: #{provider_report.fetch("ready") ? "ready" : "not-ready"} (enforceable records: #{provider_report.fetch("enforceable_record_count")})"
    provider_report.fetch("errors").each { |error| puts "  - #{error}" }
  end
end

exit(report.fetch("ready") ? 0 : 1)
