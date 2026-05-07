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
  warn "fixture manifest generator usage error: #{e.message}"
  exit 2
end

if !ARGV.empty?
  warn "fixture manifest generator usage error: unexpected arguments: #{ARGV.join(" ")}"
  exit 2
end

begin
  providers = StrictModeFixtures.provider_list(options[:provider])
  providers.each do |provider|
    path = StrictModeFixtures.manifest_path(options[:root], provider)
    manifest = if path.file?
                 StrictModeFixtures.load_json(path)
               else
                 StrictModeFixtures.empty_manifest
               end
    StrictModeFixtures.write_manifest(path, manifest)
  end
rescue RuntimeError, SystemCallError, ArgumentError => e
  warn "fixture manifest generation failed: #{e.message}"
  exit 1
end
