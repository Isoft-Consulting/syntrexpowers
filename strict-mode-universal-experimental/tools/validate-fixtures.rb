#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"
require_relative "fixture_manifest_lib"

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
  warn "fixture validator usage error: #{e.message}"
  exit 2
end

if !ARGV.empty?
  warn "fixture validator usage error: unexpected arguments: #{ARGV.join(" ")}"
  exit 2
end

begin
  errors = StrictModeFixtures.provider_list(options[:provider]).flat_map do |provider|
    StrictModeFixtures.validate_provider_manifest(options[:root], provider)
  end
rescue RuntimeError, ArgumentError => e
  warn "fixture validation failed: #{e.message}"
  exit 1
end

if errors.empty?
  puts "fixture validation passed"
  exit 0
end

errors.each { |error| warn error }
exit 1
