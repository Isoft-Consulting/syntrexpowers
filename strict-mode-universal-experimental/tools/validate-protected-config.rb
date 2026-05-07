#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require_relative "protected_config_lib"

def usage_error(message)
  warn "protected config usage error: #{message}"
  exit 2
end

options = {
  kind: nil,
  path: nil,
  line_max_bytes: StrictModeProtectedConfig::DEFAULT_LINE_MAX_BYTES,
  json: false
}

begin
  OptionParser.new do |opts|
    opts.on("--kind KIND") { |value| options[:kind] = value }
    opts.on("--path PATH") { |value| options[:path] = Pathname.new(value) }
    opts.on("--line-max-bytes N") do |value|
      parsed = Integer(value, exception: false)
      usage_error("--line-max-bytes must be an integer") if parsed.nil?

      options[:line_max_bytes] = parsed
    end
    opts.on("--json") { options[:json] = true }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end

usage_error("--kind is required") unless options[:kind]
usage_error("--path is required") unless options[:path]
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

begin
  result = StrictModeProtectedConfig.parse_file(
    options[:path],
    kind: options[:kind],
    line_max_bytes: options[:line_max_bytes]
  )
rescue ArgumentError => e
  usage_error(e.message)
end

if options[:json]
  puts JSON.pretty_generate(result)
else
  result.fetch("config_errors").each { |message| warn "protected config warning: #{message}" }
  result.fetch("errors").each { |message| warn "protected config error: #{message}" }
  puts "protected config validation passed" if result.fetch("errors").empty?
end

exit(result.fetch("errors").empty? ? 0 : 1)
