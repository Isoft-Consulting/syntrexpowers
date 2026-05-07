#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"
require_relative "preflight_record_lib"

def usage_error(message)
  warn "preflight record usage error: #{message}"
  exit 2
end

def fail_validate(message)
  warn "preflight record validation failed: #{message}"
  exit 1
end

options = { path: nil }

begin
  OptionParser.new do |opts|
    opts.banner = "Usage: validate-preflight-record.rb --path PATH"
    opts.on("--path PATH") { |value| options[:path] = Pathname.new(value) }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
usage_error("--path is required") unless options[:path]

begin
  record = StrictModePreflightRecord.load_json(options[:path])
  errors = StrictModePreflightRecord.validate(record)
  raise errors.join("\n") unless errors.empty?

  puts "preflight record validation passed"
rescue RuntimeError, SystemCallError, ArgumentError => e
  fail_validate(e.message)
end
