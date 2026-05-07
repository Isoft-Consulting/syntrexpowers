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
  provider: "all"
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

begin
  providers = StrictModeFixtures.provider_list(options[:provider])
  errors = StrictModeFixtureReadiness.enforcing_errors(options[:root], providers)
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
