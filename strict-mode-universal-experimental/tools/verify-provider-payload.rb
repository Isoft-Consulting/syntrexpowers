#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "pathname"
require_relative "provider_detection_lib"

def usage_error(message)
  warn "provider verification usage error: #{message}"
  exit 2
end

def fail_verify(message)
  warn "provider verification failed: #{message}"
  exit 1
end

options = {
  provider: nil,
  provider_source: "argv",
  source: nil,
  validate_proof: nil
}

begin
  OptionParser.new do |opts|
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--provider-source SOURCE") { |value| options[:provider_source] = value }
    opts.on("--source PATH") { |value| options[:source] = value }
    opts.on("--validate-proof PATH") { |value| options[:validate_proof] = Pathname.new(value) }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

begin
  if options[:validate_proof]
    record = JSON.parse(options[:validate_proof].read, object_class: StrictModeFixtures::DuplicateKeyHash)
    errors = StrictModeProviderDetection.validate(JSON.parse(JSON.generate(record)))
    raise errors.join("\n") unless errors.empty?

    puts "provider proof validation passed"
    exit 0
  end

  usage_error("--provider is required") unless options[:provider]
  usage_error("--source is required") unless options[:source]

  payload_bytes, payload = StrictModeProviderDetection.load_payload(options[:source])
  record = StrictModeProviderDetection.proof(
    payload,
    provider_arg: options[:provider],
    provider_arg_source: options[:provider_source],
    payload_sha256: Digest::SHA256.hexdigest(payload_bytes)
  )
  puts JSON.pretty_generate(record)
  raise record.fetch("diagnostic") unless record.fetch("decision") == "match"
rescue JSON::ParserError, SystemCallError, RuntimeError, ArgumentError => e
  fail_verify(e.message)
end
