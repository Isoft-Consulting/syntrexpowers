#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "pathname"
require_relative "normalized_event_lib"

def usage_error(message)
  warn "normalize-event usage error: #{message}"
  exit 2
end

def fail_normalize(message)
  warn "normalize-event failed: #{message}"
  exit 1
end

options = {
  provider: nil,
  logical_event: nil,
  source: nil,
  cwd: Dir.pwd,
  project_dir: Dir.pwd,
  validate_only: false
}

begin
  OptionParser.new do |opts|
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--logical-event EVENT") { |value| options[:logical_event] = value }
    opts.on("--source PATH") { |value| options[:source] = value }
    opts.on("--cwd PATH") { |value| options[:cwd] = value }
    opts.on("--project-dir PATH") { |value| options[:project_dir] = value }
    opts.on("--validate-normalized PATH") { |value| options[:validate_only] = Pathname.new(value) }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

begin
  if options[:validate_only]
    event = JSON.parse(options[:validate_only].read, object_class: StrictModeFixtures::DuplicateKeyHash)
    errors = StrictModeNormalized.validate(JSON.parse(JSON.generate(event)))
    raise errors.join("\n") unless errors.empty?

    puts "normalized event validation passed"
    exit 0
  end

  usage_error("--provider is required") unless options[:provider]
  usage_error("--logical-event is required") unless options[:logical_event]
  usage_error("--source is required") unless options[:source]

  payload_bytes, payload = StrictModeNormalized.load_payload(options[:source])
  event = StrictModeNormalized.normalize(
    payload,
    provider: options[:provider],
    logical_event: options[:logical_event],
    cwd: options[:cwd],
    project_dir: options[:project_dir],
    payload_sha256: Digest::SHA256.hexdigest(payload_bytes)
  )
  puts JSON.pretty_generate(event)
rescue JSON::ParserError, SystemCallError, RuntimeError, ArgumentError => e
  fail_normalize(e.message)
end
