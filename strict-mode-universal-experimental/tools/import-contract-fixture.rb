#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require_relative "decision_contract_lib"
require_relative "fixture_manifest_lib"

MAX_SOURCE_BYTES = 1_048_576
GENERIC_CONTRACT_KINDS = %w[
  matcher
  command-execution
  event-order
  prompt-extraction
  judge-invocation
  worker-invocation
  version-comparator
].freeze

def usage_error(message)
  warn "contract fixture import usage error: #{message}"
  exit 2
end

def fail_import(message)
  warn "contract fixture import failed: #{message}"
  exit 1
end

def sha?(value)
  value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
end

def source_file(path)
  input_path = Pathname.new(File.expand_path(path)).cleanpath
  raise "#{input_path}: source path must not be a symlink" if input_path.symlink?

  path = Pathname.new(File.realpath(input_path))
  raise "#{path}: source is not a file" unless path.file?
  raise "#{path}: source is too large" if path.size > MAX_SOURCE_BYTES

  path
end

def fixture_hash_entry(root, path)
  {
    "path" => path.relative_path_from(Pathname.new(root)).to_s,
    "content_sha256" => Digest::SHA256.file(path).hexdigest
  }
end

def compatibility_for(provider_version, provider_build_hash)
  if provider_version == "unknown"
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
      "min_version" => provider_version,
      "max_version" => provider_version,
      "version_comparator" => "",
      "provider_build_hashes" => provider_build_hash.empty? ? [] : [provider_build_hash]
    }
  end
end

def default_contract_id(provider, event, contract_kind)
  suffix = case contract_kind
           when "command-execution"
             "command"
           when "event-order"
             "order"
           when "decision-output"
             "decision"
           else
             contract_kind
           end
  "#{provider}.#{StrictModeFixtures.safe_component(event)}.#{suffix}"
end

def contract_hash_fields(contract_kind, surface_hash, decision_contract_hash = StrictModeFixtures::ZERO_HASH)
  payload_schema_hash = StrictModeFixtures::ZERO_HASH
  decision_hash = StrictModeFixtures::ZERO_HASH
  command_hash = StrictModeFixtures::ZERO_HASH

  case contract_kind
  when "payload-schema", "prompt-extraction"
    payload_schema_hash = surface_hash
  when "command-execution"
    command_hash = surface_hash
  when "decision-output"
    decision_hash = decision_contract_hash
  when "judge-invocation", "worker-invocation"
    decision_hash = surface_hash
    command_hash = surface_hash
  end

  [payload_schema_hash, decision_hash, command_hash]
end

def copy_fixture!(root, provider, fixture_name, source, replace)
  fixture_relative = "providers/#{provider}/fixtures/#{fixture_name}"
  destination = StrictModeFixtures.fixture_path_for(root, provider, fixture_relative)
  raise "#{fixture_relative}: fixture destination is not a safe provider fixture path" unless destination
  raise "#{destination}: fixture destination must not be a symlink" if destination.symlink?
  if destination.file? && Digest::SHA256.file(destination).hexdigest != Digest::SHA256.file(source).hexdigest && !replace
    raise "#{destination}: fixture destination already exists with different content; pass --replace to update it"
  end

  destination.dirname.mkpath
  FileUtils.cp(source, destination)
  File.chmod(0o600, destination)
  destination
end

def default_fixture_name(contract_kind, event, contract_id, source, index, total)
  event_component = StrictModeFixtures.safe_component(event)
  contract_component = StrictModeFixtures.safe_component(contract_id)
  basename = StrictModeFixtures.safe_component(source.basename.to_s)
  suffix = total == 1 ? basename : "#{index + 1}-#{basename}"
  "#{contract_kind}/#{event_component}/#{contract_component}.#{suffix}"
end

def load_manifest(root, provider, captured_at)
  manifest_path = StrictModeFixtures.manifest_path(root, provider)
  if manifest_path.file?
    errors = StrictModeFixtures.validate_provider_manifest(root, provider)
    raise errors.join("\n") unless errors.empty?

    StrictModeFixtures.load_json(manifest_path)
  else
    StrictModeFixtures.empty_manifest(captured_at)
  end
end

def write_record!(root, provider, record, captured_at, replace)
  manifest_path = StrictModeFixtures.manifest_path(root, provider)
  manifest = load_manifest(root, provider, captured_at)
  records = manifest.fetch("records")
  existing_index = records.index { |item| item.is_a?(Hash) && item["contract_id"] == record.fetch("contract_id") }
  raise "#{record.fetch("contract_id")}: contract already exists; pass --replace to update it" if existing_index && !replace

  if existing_index
    records[existing_index] = record
  else
    records << record
  end
  manifest["records"] = records.sort_by { |item| item.fetch("contract_id") }
  StrictModeFixtures.write_manifest(manifest_path, manifest)
end

options = {
  root: StrictModeFixtures.project_root,
  provider: nil,
  event: nil,
  contract_kind: nil,
  contract_id: nil,
  sources: [],
  fixture_names: [],
  metadata: nil,
  stdout: nil,
  stderr: nil,
  exit_code: nil,
  provider_version: "unknown",
  provider_build_hash: "",
  platform: RUBY_PLATFORM,
  captured_at: nil,
  replace: false
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--event EVENT") { |value| options[:event] = value }
    opts.on("--contract-kind KIND") { |value| options[:contract_kind] = value }
    opts.on("--contract-id ID") { |value| options[:contract_id] = value }
    opts.on("--source PATH") { |value| options[:sources] << value }
    opts.on("--fixture-name NAME") { |value| options[:fixture_names] << value }
    opts.on("--metadata PATH") { |value| options[:metadata] = value }
    opts.on("--stdout PATH") { |value| options[:stdout] = value }
    opts.on("--stderr PATH") { |value| options[:stderr] = value }
    opts.on("--exit-code PATH") { |value| options[:exit_code] = value }
    opts.on("--provider-version VERSION") { |value| options[:provider_version] = value }
    opts.on("--provider-build-hash SHA") { |value| options[:provider_build_hash] = value }
    opts.on("--platform PLATFORM") { |value| options[:platform] = value }
    opts.on("--captured-at ISO8601") { |value| options[:captured_at] = value }
    opts.on("--replace") { options[:replace] = true }
  end.parse!(ARGV)
rescue OptionParser::ParseError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
usage_error("--provider is required") unless options[:provider]
usage_error("--event is required") unless options[:event]
usage_error("--contract-kind is required") unless options[:contract_kind]

begin
  provider = options[:provider]
  contract_kind = options[:contract_kind]
  raise "--provider must be claude or codex" unless %w[claude codex].include?(provider)
  raise "--event must be a non-empty string" unless options[:event].is_a?(String) && !options[:event].empty?
  raise "--provider-version must be a non-empty string" unless options[:provider_version].is_a?(String) && !options[:provider_version].empty?
  raise "--provider-build-hash must be empty or lowercase SHA-256" unless options[:provider_build_hash].empty? || sha?(options[:provider_build_hash])
  raise "--provider-build-hash requires a known provider version" if options[:provider_version] == "unknown" && !options[:provider_build_hash].empty?
  raise "--contract-kind payload-schema must use import-discovery-fixture.rb" if contract_kind == "payload-schema"
  raise "--contract-kind must be #{(GENERIC_CONTRACT_KINDS + ["decision-output"]).join(", ")}" unless (GENERIC_CONTRACT_KINDS + ["decision-output"]).include?(contract_kind)

  captured_at = options[:captured_at] || Time.now.utc.iso8601
  Time.iso8601(captured_at)
  contract_id = options[:contract_id] || default_contract_id(provider, options[:event], contract_kind)
  raise "--contract-id must be a stable lowercase id" unless contract_id.match?(StrictModeFixtures::CONTRACT_ID_PATTERN)

  fixture_paths = if contract_kind == "decision-output"
                    raise "--source/--fixture-name are not supported for decision-output; use --metadata/--stdout/--stderr/--exit-code" unless options[:sources].empty? && options[:fixture_names].empty?
                    %i[metadata stdout stderr exit_code].each do |field|
                      raise "--#{field.to_s.tr("_", "-")} is required for decision-output" unless options[field]
                    end
                    metadata_source = source_file(options[:metadata])
                    stdout_source = source_file(options[:stdout])
                    stderr_source = source_file(options[:stderr])
                    exit_code_source = source_file(options[:exit_code])
                    metadata = StrictModeDecisionContract.load_json(metadata_source)
                    raise "decision-output metadata contract_id must match --contract-id" unless metadata["contract_id"] == contract_id
                    raise "decision-output metadata provider must match --provider" unless metadata["provider"] == provider
                    raise "decision-output metadata event must match --event" unless metadata["event"] == options[:event]
                    raise "decision-output metadata logical_event must match --event" unless metadata["logical_event"] == options[:event]
                    metadata_errors = StrictModeDecisionContract.validate_provider_output(metadata)
                    raise metadata_errors.join("\n") unless metadata_errors.empty?
                    exit_code_text = exit_code_source.read
                    raise "decision-output exit-code fixture must contain one integer 0..255" unless exit_code_text.match?(/\A(?:0|[1-9][0-9]{0,2})\n?\z/) && exit_code_text.to_i.between?(0, 255)
                    capture_errors = StrictModeDecisionContract.validate_captured_output(
                      metadata,
                      stdout_bytes: stdout_source.binread,
                      stderr_bytes: stderr_source.binread,
                      exit_code: exit_code_text.to_i
                    )
                    raise capture_errors.join("\n") unless capture_errors.empty?

                    event_component = StrictModeFixtures.safe_component(options[:event])
                    contract_component = StrictModeFixtures.safe_component(contract_id)
                    [
                      copy_fixture!(options[:root], provider, "decision-output/#{event_component}/#{contract_component}.provider-output.json", metadata_source, options[:replace]),
                      copy_fixture!(options[:root], provider, "decision-output/#{event_component}/#{contract_component}.stdout", stdout_source, options[:replace]),
                      copy_fixture!(options[:root], provider, "decision-output/#{event_component}/#{contract_component}.stderr", stderr_source, options[:replace]),
                      copy_fixture!(options[:root], provider, "decision-output/#{event_component}/#{contract_component}.exit-code", exit_code_source, options[:replace])
                    ]
                  else
                    raise "--source is required" if options[:sources].empty?
                    if !options[:fixture_names].empty? && options[:fixture_names].length != options[:sources].length
                      raise "--fixture-name must be repeated once per --source when used"
                    end
                    sources = options[:sources].map { |source| source_file(source) }
                    sources.each_with_index.map do |source, index|
                      fixture_name = options[:fixture_names][index] || default_fixture_name(contract_kind, options[:event], contract_id, source, index, sources.length)
                      copy_fixture!(options[:root], provider, fixture_name, source, options[:replace])
                    end
                  end

  fixture_file_hashes = fixture_paths.map { |path| fixture_hash_entry(options[:root], path) }.sort_by { |item| item.fetch("path") }
  surface_hash = Digest::SHA256.hexdigest(JSON.generate(fixture_file_hashes))
  decision_contract_hash = if contract_kind == "decision-output"
                             StrictModeDecisionContract.load_json(fixture_paths.find { |path| path.basename.to_s.end_with?(".provider-output.json") }).fetch("decision_contract_hash")
                           else
                             StrictModeFixtures::ZERO_HASH
                           end
  payload_schema_hash, decision_hash, command_hash = contract_hash_fields(contract_kind, surface_hash, decision_contract_hash)
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => options[:provider_version],
    "provider_build_hash" => options[:provider_build_hash],
    "platform" => options[:platform],
    "event" => options[:event],
    "contract_kind" => contract_kind,
    "payload_schema_hash" => payload_schema_hash,
    "decision_contract_hash" => decision_hash,
    "command_execution_contract_hash" => command_hash,
    "fixture_file_hashes" => fixture_file_hashes,
    "captured_at" => captured_at,
    "compatibility_range" => compatibility_for(options[:provider_version], options[:provider_build_hash]),
    "fixture_record_hash" => ""
  }
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_record!(options[:root], provider, record, captured_at, options[:replace])

  errors = StrictModeFixtures.validate_provider_manifest(options[:root], provider)
  raise errors.join("\n") unless errors.empty?
  puts "imported #{contract_kind} fixture #{contract_id}"
rescue RuntimeError, SystemCallError, JSON::ParserError, ArgumentError => e
  fail_import(e.message)
end
