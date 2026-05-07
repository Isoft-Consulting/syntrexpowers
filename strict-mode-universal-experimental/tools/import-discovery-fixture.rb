#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require_relative "fixture_manifest_lib"
require_relative "normalized_event_lib"
require_relative "provider_detection_lib"

MAX_SOURCE_BYTES = 1_048_576

def usage_error(message)
  warn "fixture import usage error: #{message}"
  exit 2
end

def fail_import(message)
  warn "fixture import failed: #{message}"
  exit 1
end

def source_payload(path)
  input_path = Pathname.new(File.expand_path(path)).cleanpath
  raise "#{input_path}: source path must not be a symlink" if input_path.symlink?

  path = Pathname.new(File.realpath(input_path))
  raise "#{path}: source payload is not a file" unless path.file?
  raise "#{path}: source payload is too large" if path.size > MAX_SOURCE_BYTES

  payload = path.binread
  begin
    parsed = JSON.parse(payload, object_class: StrictModeFixtures::DuplicateKeyHash)
  rescue JSON::ParserError => e
    raise "#{path}: source payload must be duplicate-key-safe JSON: #{e.message}"
  end
  raise "#{path}: source payload JSON root must be an object" unless parsed.is_a?(Hash)

  [path, payload, JSON.parse(JSON.generate(parsed))]
end

def contract_id_for(provider, event)
  "#{provider}.#{StrictModeFixtures.safe_component(event)}.payload"
end

def sha?(value)
  value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
end

options = {
  root: StrictModeFixtures.project_root,
  provider: nil,
  event: nil,
  logical_event: nil,
  source: nil,
  cwd: Dir.pwd,
  project_dir: Dir.pwd,
  provider_version: "unknown",
  provider_build_hash: "",
  platform: RUBY_PLATFORM,
  contract_id: nil,
  fixture_name: nil,
  normalized_fixture_name: nil,
  provider_proof_fixture_name: nil,
  captured_at: nil,
  replace: false
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--event EVENT") { |value| options[:event] = value }
    opts.on("--logical-event EVENT") { |value| options[:logical_event] = value }
    opts.on("--source PATH") { |value| options[:source] = value }
    opts.on("--cwd PATH") { |value| options[:cwd] = value }
    opts.on("--project-dir PATH") { |value| options[:project_dir] = value }
    opts.on("--provider-version VERSION") { |value| options[:provider_version] = value }
    opts.on("--provider-build-hash SHA") { |value| options[:provider_build_hash] = value }
    opts.on("--platform PLATFORM") { |value| options[:platform] = value }
    opts.on("--contract-id ID") { |value| options[:contract_id] = value }
    opts.on("--fixture-name NAME") { |value| options[:fixture_name] = value }
    opts.on("--normalized-fixture-name NAME") { |value| options[:normalized_fixture_name] = value }
    opts.on("--provider-proof-fixture-name NAME") { |value| options[:provider_proof_fixture_name] = value }
    opts.on("--captured-at ISO8601") { |value| options[:captured_at] = value }
    opts.on("--replace") { options[:replace] = true }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
usage_error("--provider is required") unless options[:provider]
usage_error("--event is required") unless options[:event]
usage_error("--source is required") unless options[:source]

begin
  provider = options[:provider]
  raise "--provider must be claude or codex" unless %w[claude codex].include?(provider)
  raise "--event must be a non-empty string" unless options[:event].is_a?(String) && !options[:event].empty?
  raise "--provider-version must be a non-empty string" unless options[:provider_version].is_a?(String) && !options[:provider_version].empty?
  raise "--provider-build-hash must be empty or lowercase SHA-256" unless options[:provider_build_hash].empty? || sha?(options[:provider_build_hash])
  raise "--provider-build-hash requires a known provider version" if options[:provider_version] == "unknown" && !options[:provider_build_hash].empty?

  captured_at = options[:captured_at] || Time.now.utc.iso8601
  Time.iso8601(captured_at)
  source_path, payload, parsed_payload = source_payload(options[:source])
  payload_hash = Digest::SHA256.hexdigest(payload)
  provider_proof = StrictModeProviderDetection.proof(
    parsed_payload,
    provider_arg: provider,
    provider_arg_source: "fixture-import",
    payload_sha256: payload_hash
  )
  provider_proof_errors = StrictModeProviderDetection.validate(provider_proof)
  raise provider_proof_errors.join("\n") unless provider_proof_errors.empty?
  raise "provider detection #{provider_proof.fetch("decision")}: #{provider_proof.fetch("diagnostic")}" unless provider_proof.fetch("decision") == "match"

  logical_event = options[:logical_event] || StrictModeNormalized.native_logical_event(options[:event])
  raise "--logical-event is required when --event is not a supported native or logical event" if logical_event.empty?
  raise "--logical-event must be a supported logical event" unless StrictModeNormalized::LOGICAL_EVENTS.include?(logical_event)
  normalized_event = StrictModeNormalized.normalize(
    parsed_payload,
    provider: provider,
    logical_event: logical_event,
    cwd: options[:cwd],
    project_dir: options[:project_dir],
    payload_sha256: payload_hash
  )
  event_component = StrictModeFixtures.safe_component(logical_event)
  contract_id = options[:contract_id] || contract_id_for(provider, logical_event)
  raise "--contract-id must be a stable lowercase id" unless contract_id.match?(StrictModeFixtures::CONTRACT_ID_PATTERN)

  fixture_name = options[:fixture_name] || "payloads/#{event_component}/#{payload_hash[0, 16]}.json"
  fixture_relative = "providers/#{provider}/fixtures/#{fixture_name}"
  destination = StrictModeFixtures.fixture_path_for(options[:root], provider, fixture_relative)
  raise "#{fixture_relative}: fixture destination is not a safe provider fixture path" unless destination
  raise "#{destination}: fixture destination must not be a symlink" if destination.symlink?
  if destination.file? && Digest::SHA256.file(destination).hexdigest != payload_hash
    raise "#{destination}: fixture destination already exists with different content"
  end
  normalized_fixture_name = options[:normalized_fixture_name] || "normalized/#{event_component}/#{payload_hash[0, 16]}.event.normalized.json"
  normalized_fixture_relative = "providers/#{provider}/fixtures/#{normalized_fixture_name}"
  normalized_destination = StrictModeFixtures.fixture_path_for(options[:root], provider, normalized_fixture_relative)
  raise "#{normalized_fixture_relative}: normalized fixture destination is not a safe provider fixture path" unless normalized_destination
  raise "#{normalized_destination}: normalized fixture destination must not be a symlink" if normalized_destination.symlink?
  normalized_json = JSON.pretty_generate(normalized_event) + "\n"
  if normalized_destination.file? && Digest::SHA256.file(normalized_destination).hexdigest != Digest::SHA256.hexdigest(normalized_json) && !options[:replace]
    raise "#{normalized_destination}: normalized fixture destination already exists with different content; pass --replace to update it"
  end
  provider_proof_fixture_name = options[:provider_proof_fixture_name] || "provider-proof/#{event_component}/#{payload_hash[0, 16]}.provider-detection.json"
  provider_proof_fixture_relative = "providers/#{provider}/fixtures/#{provider_proof_fixture_name}"
  provider_proof_destination = StrictModeFixtures.fixture_path_for(options[:root], provider, provider_proof_fixture_relative)
  raise "#{provider_proof_fixture_relative}: provider proof fixture destination is not a safe provider fixture path" unless provider_proof_destination
  raise "#{provider_proof_destination}: provider proof fixture destination must not be a symlink" if provider_proof_destination.symlink?
  provider_proof_json = JSON.pretty_generate(provider_proof) + "\n"
  if provider_proof_destination.file? && Digest::SHA256.file(provider_proof_destination).hexdigest != Digest::SHA256.hexdigest(provider_proof_json) && !options[:replace]
    raise "#{provider_proof_destination}: provider proof fixture destination already exists with different content; pass --replace to update it"
  end

  manifest_path = StrictModeFixtures.manifest_path(options[:root], provider)
  manifest = if manifest_path.file?
               errors = StrictModeFixtures.validate_provider_manifest(options[:root], provider)
               raise errors.join("\n") unless errors.empty?

               StrictModeFixtures.load_json(manifest_path)
             else
               StrictModeFixtures.empty_manifest(captured_at)
             end
  records = manifest.fetch("records")
  existing_index = records.index { |record| record.is_a?(Hash) && record["contract_id"] == contract_id }
  raise "#{contract_id}: contract already exists; pass --replace to update it" if existing_index && !options[:replace]

  destination.dirname.mkpath
  destination.binwrite(payload)
  File.chmod(0o600, destination)
  normalized_destination.dirname.mkpath
  normalized_destination.write(normalized_json)
  File.chmod(0o600, normalized_destination)
  provider_proof_destination.dirname.mkpath
  provider_proof_destination.write(provider_proof_json)
  File.chmod(0o600, provider_proof_destination)

  fixture_file_hashes = [
    {
      "path" => destination.relative_path_from(Pathname.new(options[:root])).to_s,
      "content_sha256" => payload_hash
    },
    {
      "path" => normalized_destination.relative_path_from(Pathname.new(options[:root])).to_s,
      "content_sha256" => Digest::SHA256.hexdigest(normalized_json)
    },
    {
      "path" => provider_proof_destination.relative_path_from(Pathname.new(options[:root])).to_s,
      "content_sha256" => Digest::SHA256.hexdigest(provider_proof_json)
    }
  ].sort_by { |item| item.fetch("path") }
  compatibility = if options[:provider_version] == "unknown"
                    {
                      "mode" => "unknown-only",
                      "min_version" => "unknown",
                      "max_version" => "unknown",
                      "version_comparator" => "",
                      "provider_build_hashes" => []
                    }
                  else
                    {
                      "mode" => "exact",
                      "min_version" => options[:provider_version],
                      "max_version" => options[:provider_version],
                      "version_comparator" => "",
                      "provider_build_hashes" => options[:provider_build_hash].empty? ? [] : [options[:provider_build_hash]]
                    }
                  end
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => options[:provider_version],
    "provider_build_hash" => options[:provider_build_hash],
    "platform" => options[:platform],
    "event" => logical_event,
    "contract_kind" => "payload-schema",
    "payload_schema_hash" => StrictModeFixtures.payload_schema_hash(provider, logical_event, parsed_payload, normalized_event, provider_proof),
    "decision_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => fixture_file_hashes,
    "captured_at" => captured_at,
    "compatibility_range" => compatibility,
    "fixture_record_hash" => ""
  }
  if existing_index
    records[existing_index] = record
  else
    records << record
  end
  manifest["records"] = records.sort_by { |item| item.fetch("contract_id") }
  StrictModeFixtures.write_manifest(manifest_path, manifest)
  errors = StrictModeFixtures.validate_provider_manifest(options[:root], provider)
  raise errors.join("\n") unless errors.empty?

  puts JSON.pretty_generate({
    "schema_version" => 1,
    "imported" => true,
    "provider" => provider,
    "event" => logical_event,
    "contract_id" => contract_id,
    "source_path" => source_path.to_s,
    "fixture_paths" => fixture_file_hashes.map { |item| item.fetch("path") },
    "normalized_fixture_path" => normalized_destination.relative_path_from(Pathname.new(options[:root])).to_s,
    "provider_proof_fixture_path" => provider_proof_destination.relative_path_from(Pathname.new(options[:root])).to_s,
    "payload_sha256" => payload_hash
  })
rescue SystemCallError, RuntimeError, ArgumentError => e
  fail_import(e.message)
end
