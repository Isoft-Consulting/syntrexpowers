#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "time"
require_relative "fixture_manifest_lib"
require_relative "normalized_event_lib"

def usage_error(message)
  warn "raw capture import usage error: #{message}"
  exit 2
end

def fail_import(message)
  warn "raw capture import failed: #{message}"
  exit 1
end

def sha?(value)
  value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
end

def safe_capture_files(capture_root, provider, event)
  event_component = StrictModeFixtures.safe_component(event)
  dir = Pathname.new(capture_root).join(provider, event_component)
  return [] unless dir.directory? && !dir.symlink?

  Dir.glob(dir.join("*.payload").to_s).sort.map do |path|
    file = Pathname.new(path)
    raise "#{file}: raw capture must not be a symlink" if file.symlink?
    raise "#{file}: raw capture must be a file" unless file.file?

    file
  end
end

options = {
  root: StrictModeFixtures.project_root,
  provider: nil,
  event: "all",
  state_root: nil,
  capture_root: nil,
  cwd: Dir.pwd,
  project_dir: Dir.pwd,
  provider_version: "unknown",
  provider_build_hash: "",
  platform: RUBY_PLATFORM,
  captured_at: nil,
  replace: false,
  dry_run: false
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--event EVENT") { |value| options[:event] = value }
    opts.on("--state-root PATH") { |value| options[:state_root] = Pathname.new(value) }
    opts.on("--capture-root PATH") { |value| options[:capture_root] = Pathname.new(value) }
    opts.on("--cwd PATH") { |value| options[:cwd] = value }
    opts.on("--project-dir PATH") { |value| options[:project_dir] = value }
    opts.on("--provider-version VERSION") { |value| options[:provider_version] = value }
    opts.on("--provider-build-hash SHA") { |value| options[:provider_build_hash] = value }
    opts.on("--platform PLATFORM") { |value| options[:platform] = value }
    opts.on("--captured-at ISO8601") { |value| options[:captured_at] = value }
    opts.on("--replace") { options[:replace] = true }
    opts.on("--dry-run") { options[:dry_run] = true }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
usage_error("--provider is required") unless options[:provider]
usage_error("--state-root or --capture-root is required") unless options[:state_root] || options[:capture_root]

begin
  provider = options[:provider]
  raise "--provider must be claude or codex" unless %w[claude codex].include?(provider)
  raise "--event must be all or a supported logical event" unless options[:event] == "all" || StrictModeNormalized::LOGICAL_EVENTS.include?(options[:event])
  raise "--provider-version must be a non-empty string" unless options[:provider_version].is_a?(String) && !options[:provider_version].empty?
  raise "--provider-build-hash must be empty or lowercase SHA-256" unless options[:provider_build_hash].empty? || sha?(options[:provider_build_hash])
  raise "--provider-build-hash requires a known provider version" if options[:provider_version] == "unknown" && !options[:provider_build_hash].empty?
  Time.iso8601(options[:captured_at]) if options[:captured_at]

  capture_root = options[:capture_root] || options[:state_root].join("discovery/raw")
  raise "#{capture_root}: capture root must not be a symlink" if capture_root.symlink?
  events = if options[:event] == "all"
             provider_root = capture_root.join(provider)
             provider_root.directory? ? provider_root.children.select(&:directory?).map { |path| path.basename.to_s }.sort : []
           else
             [options[:event]]
           end
  events &= StrictModeNormalized::LOGICAL_EVENTS
  files = events.flat_map { |event| safe_capture_files(capture_root, provider, event).map { |path| [event, path] } }
  raise "no raw captures found for #{provider} #{options[:event]}" if files.empty?

  importer = StrictModeMetadata.project_root.join("tools/import-discovery-fixture.rb")
  imported = 0
  files.each do |event, source|
    payload_hash = Digest::SHA256.file(source).hexdigest
    contract_id = "#{provider}.#{StrictModeFixtures.safe_component(event)}.payload.#{payload_hash[0, 12]}"
    captured_at = options[:captured_at] || source.mtime.utc.iso8601
    if options[:dry_run]
      puts "would import #{source} as #{contract_id}"
      next
    end

    args = [
      RbConfig.ruby,
      importer.to_s,
      "--root", options[:root].to_s,
      "--provider", provider,
      "--event", event,
      "--logical-event", event,
      "--source", source.to_s,
      "--cwd", options[:cwd].to_s,
      "--project-dir", options[:project_dir].to_s,
      "--provider-version", options[:provider_version],
      "--platform", options[:platform],
      "--contract-id", contract_id,
      "--captured-at", captured_at
    ]
    args.concat(["--provider-build-hash", options[:provider_build_hash]]) unless options[:provider_build_hash].empty?
    args << "--replace" if options[:replace]
    stdout, stderr, status = Open3.capture3(*args)
    unless status.success?
      raise "#{source}: import-discovery-fixture failed\n#{stdout}#{stderr}"
    end
    imported += 1
  end

  puts options[:dry_run] ? "raw capture import dry-run complete (#{files.length} captures)" : "imported #{imported} raw captures"
rescue RuntimeError, SystemCallError, JSON::ParserError, ArgumentError => e
  fail_import(e.message)
end
