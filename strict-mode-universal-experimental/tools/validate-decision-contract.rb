#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"
require_relative "decision_contract_lib"

def usage_error(message)
  warn "decision contract usage error: #{message}"
  exit 2
end

def fail_validate(message)
  warn "decision contract validation failed: #{message}"
  exit 1
end

options = {
  internal: nil,
  provider_output: nil,
  stdout: nil,
  stderr: nil,
  exit_code: nil
}

begin
  OptionParser.new do |opts|
    opts.on("--internal PATH") { |value| options[:internal] = Pathname.new(value) }
    opts.on("--provider-output PATH") { |value| options[:provider_output] = Pathname.new(value) }
    opts.on("--stdout PATH") { |value| options[:stdout] = Pathname.new(value) }
    opts.on("--stderr PATH") { |value| options[:stderr] = Pathname.new(value) }
    opts.on("--exit-code CODE") do |value|
      parsed = Integer(value, exception: false)
      usage_error("--exit-code must be an integer") if parsed.nil?

      options[:exit_code] = parsed
    end
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

begin
  if options[:internal]
    usage_error("--internal cannot be combined with provider output options") if options[:provider_output] || options[:stdout] || options[:stderr] || !options[:exit_code].nil?

    record = StrictModeDecisionContract.load_json(options[:internal])
    errors = StrictModeDecisionContract.validate_internal(record)
    raise errors.join("\n") unless errors.empty?

    puts "internal decision validation passed"
    exit 0
  end

  usage_error("--provider-output is required") unless options[:provider_output]
  metadata = StrictModeDecisionContract.load_json(options[:provider_output])
  if options[:stdout] || options[:stderr] || !options[:exit_code].nil?
    usage_error("--stdout is required with captured output validation") unless options[:stdout]
    usage_error("--stderr is required with captured output validation") unless options[:stderr]
    usage_error("--exit-code is required with captured output validation") if options[:exit_code].nil?

    errors = StrictModeDecisionContract.validate_captured_output(
      metadata,
      stdout_bytes: options[:stdout].binread,
      stderr_bytes: options[:stderr].binread,
      exit_code: options[:exit_code]
    )
  else
    errors = StrictModeDecisionContract.validate_provider_output(metadata)
  end
  raise errors.join("\n") unless errors.empty?

  puts "provider output validation passed"
rescue RuntimeError, SystemCallError, ArgumentError => e
  fail_validate(e.message)
end
