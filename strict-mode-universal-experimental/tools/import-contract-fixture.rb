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

def fixture_destination!(root, provider, fixture_name, source, replace)
  fixture_relative = "providers/#{provider}/fixtures/#{fixture_name}"
  destination = StrictModeFixtures.fixture_path_for(root, provider, fixture_relative)
  raise "#{fixture_relative}: fixture destination is not a safe provider fixture path" unless destination
  raise "#{destination}: fixture destination must not be a symlink" if destination.symlink?
  if destination.file? && Digest::SHA256.file(destination).hexdigest != Digest::SHA256.file(source).hexdigest && !replace
    raise "#{destination}: fixture destination already exists with different content; pass --replace to update it"
  end

  destination
end

def preflight_fixture_writes!(root, provider, fixture_sources, replace)
  fixture_sources.each do |fixture_name, source|
    fixture_destination!(root, provider, fixture_name, source, replace)
  end
end

def copy_fixture!(root, provider, fixture_name, source, replace)
  destination = fixture_destination!(root, provider, fixture_name, source, replace)
  destination.dirname.mkpath
  FileUtils.cp(source, destination)
  File.chmod(0o600, destination)
  destination
end

def default_fixture_name(contract_kind, event, contract_id, source, index, total)
  event_component = StrictModeFixtures.safe_component(event)
  contract_component = StrictModeFixtures.safe_component(contract_id)
  if StrictModeFixtures.typed_generic_contract_kind?(contract_kind)
    return "#{contract_kind}/#{event_component}/#{contract_component}.#{contract_kind}.json"
  end

  basename = StrictModeFixtures.safe_component(source.basename.to_s)
  suffix = total == 1 ? basename : "#{index + 1}-#{basename}"
  "#{contract_kind}/#{event_component}/#{contract_component}.#{suffix}"
end

def validate_discovery_source_shape(root, provider, expected_event, discovery_source, label)
  discovery = StrictModeFixtures.load_json(discovery_source)
  errors = []
  %w[recorded_at provider event mode provider_detection_decision provider_proof_hash payload_sha256 raw_payload_path].each do |field|
    errors << "#{label}.discovery_record #{field} must be a string" unless discovery[field].is_a?(String)
  end
  errors << "#{label}.discovery_record raw_payload_captured must be boolean" unless [true, false].include?(discovery["raw_payload_captured"])
  errors << "#{label}.discovery_record provider must match fixture record" unless discovery["provider"] == provider
  errors << "#{label}.discovery_record event must match fixture record" unless discovery["event"] == expected_event
  errors << "#{label}.discovery_record mode must be discovery-log-only or enforcing" unless StrictModeFixtures::HOOK_MODES.include?(discovery["mode"])
  errors << "#{label}.discovery_record provider_detection_decision must be match" unless discovery["provider_detection_decision"] == "match"
  errors << "#{label}.discovery_record payload_sha256 must be lowercase SHA-256" unless sha?(discovery["payload_sha256"])
  errors << "#{label}.discovery_record provider_proof_hash must be lowercase SHA-256" unless sha?(discovery["provider_proof_hash"])
  begin
    Time.iso8601(discovery["recorded_at"]) if discovery["recorded_at"].is_a?(String)
  rescue ArgumentError
    errors << "#{label}.discovery_record recorded_at must be ISO-8601"
  end
  [discovery, errors]
end

def validate_discovery_source_binding!(root, provider, event, proof, discovery_source, label)
  discovery, errors = validate_discovery_source_shape(root, provider, event, discovery_source, label)
  errors << "#{label}.discovery_record payload_sha256 must match proof" unless discovery["payload_sha256"] == proof["payload_sha256"]
  errors << "#{label}.discovery_record raw_payload_path must match proof" unless discovery["raw_payload_path"] == proof["raw_payload_path"]
  errors << "#{label}.discovery_record raw_payload_captured must match proof" unless discovery["raw_payload_captured"] == proof["raw_payload_captured"]
  errors << "#{label}.discovery_record mode must match proof" unless discovery["mode"] == proof["hook_mode"]
  errors << "#{label}.discovery_record recorded_at must match proof" unless discovery["recorded_at"] == proof["discovery_recorded_at"]
  errors << "#{label}.discovery_record provider_detection_decision must match proof" unless discovery["provider_detection_decision"] == proof["provider_detection_decision"]
  StrictModeFixtures.validate_payload_hash_has_raw_fixture(
    errors,
    Pathname.new(root),
    Pathname.new("import-contract-fixture"),
    provider,
    event,
    proof["payload_sha256"],
    label,
    provider_proof_hash: discovery["provider_proof_hash"]
  )
  raise errors.join("\n") unless errors.empty?

  discovery
end

def validate_matcher_discovery_source_binding!(root, provider, event, proof, discovery_source, label)
  discovery, errors = validate_discovery_source_shape(root, provider, event, discovery_source, label)
  errors << "#{label}.discovery_record payload_sha256 must match proof" unless discovery["payload_sha256"] == proof["payload_sha256"]
  errors << "#{label}.discovery_record raw_payload_path must match proof" unless discovery["raw_payload_path"] == proof["raw_payload_path"]
  errors << "#{label}.discovery_record provider_detection_decision must match proof" unless discovery["provider_detection_decision"] == proof["provider_detection_decision"]
  StrictModeFixtures.validate_payload_hash_has_raw_fixture(
    errors,
    Pathname.new(root),
    Pathname.new("import-contract-fixture"),
    provider,
    event,
    proof["payload_sha256"],
    label,
    provider_proof_hash: discovery["provider_proof_hash"]
  )
  raise errors.join("\n") unless errors.empty?

  discovery
end

def validate_event_order_discovery_source!(root, provider, item, discovery_source, label)
  discovery, errors = validate_discovery_source_shape(root, provider, item["event"], discovery_source, label)
  errors << "#{label}.discovery_record payload_sha256 must match observed order" unless discovery["payload_sha256"] == item["payload_sha256"]
  errors << "#{label}.discovery_record recorded_at must match observed order" unless discovery["recorded_at"] == item["recorded_at"]
  StrictModeFixtures.validate_payload_hash_has_raw_fixture(
    errors,
    Pathname.new(root),
    Pathname.new("import-contract-fixture"),
    provider,
    item["event"],
    item["payload_sha256"],
    label,
    provider_proof_hash: discovery["provider_proof_hash"]
  )
  raise errors.join("\n") unless errors.empty?

  discovery
end

def validate_command_execution_sources!(root, provider, event, proof, discovery_source, stdout_source, stderr_source, exit_code_source, label)
  validate_discovery_source_binding!(root, provider, event, proof, discovery_source, label)

  errors = []
  errors << "#{label}.stdout_sha256 must match --stdout" unless Digest::SHA256.file(stdout_source).hexdigest == proof["stdout_sha256"]
  errors << "#{label}.stderr_sha256 must match --stderr" unless Digest::SHA256.file(stderr_source).hexdigest == proof["stderr_sha256"]
  exit_code_text = exit_code_source.read
  if !exit_code_text.match?(/\A(?:0|[1-9][0-9]{0,2})\n?\z/) || !exit_code_text.to_i.between?(0, 255)
    errors << "#{label}.exit-code must contain one integer 0..255"
  elsif exit_code_text.to_i != proof["hook_exit_status"]
    errors << "#{label}.hook_exit_status must match --exit-code"
  end
  raise errors.join("\n") unless errors.empty?
end

def validate_event_order_sources!(root, provider, proof, discovery_sources, label)
  observed = proof.fetch("observed_order")
  loaded = discovery_sources.map do |source|
    discovery = StrictModeFixtures.load_json(source)
    [source, discovery]
  end
  errors = []
  observed.each_with_index do |item, index|
    matching_source = loaded.find do |_source, discovery|
      discovery["event"] == item["event"] &&
        discovery["payload_sha256"] == item["payload_sha256"] &&
        discovery["recorded_at"] == item["recorded_at"]
    end&.first
    errors << "#{label}.observed_order[#{index}] must be backed by a matching discovery record" unless matching_source
    validate_event_order_discovery_source!(root, provider, item, matching_source, "#{label}.observed_order[#{index}]") if matching_source
  end

  loaded.each_with_index do |(source, discovery), index|
    next if observed.any? do |item|
      discovery["event"] == item["event"] &&
        discovery["payload_sha256"] == item["payload_sha256"] &&
        discovery["recorded_at"] == item["recorded_at"]
    end

    errors << "#{label}.discovery_record[#{index}] #{source} does not match any observed_order item"
  end
  raise errors.join("\n") unless errors.empty?

  loaded
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
  discovery_records: [],
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
    opts.on("--discovery-record PATH") { |value| options[:discovery_records] << value }
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
  typed_contract_proof = nil

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
                    fixture_sources = [
                      ["decision-output/#{event_component}/#{contract_component}.provider-output.json", metadata_source],
                      ["decision-output/#{event_component}/#{contract_component}.stdout", stdout_source],
                      ["decision-output/#{event_component}/#{contract_component}.stderr", stderr_source],
                      ["decision-output/#{event_component}/#{contract_component}.exit-code", exit_code_source]
                    ]
                    preflight_fixture_writes!(options[:root], provider, fixture_sources, options[:replace])
                    fixture_sources.map do |fixture_name, source|
                      copy_fixture!(options[:root], provider, fixture_name, source, options[:replace])
                    end
                  else
                    raise "--source is required" if options[:sources].empty?
                    if !options[:fixture_names].empty? && options[:fixture_names].length != options[:sources].length
                      raise "--fixture-name must be repeated once per --source when used"
                    end
                    sources = options[:sources].map { |source| source_file(source) }
                    fixture_paths = []
                    if StrictModeFixtures.typed_generic_contract_kind?(contract_kind)
                      raise "#{contract_kind} contract proofs must use exactly one --source" unless sources.length == 1

                      typed_contract_proof = StrictModeFixtures.load_typed_contract_proof(sources.first)
                      proof_errors = StrictModeFixtures.validate_typed_contract_proof(
                        typed_contract_proof,
                        provider: provider,
                        event: options[:event],
                        contract_kind: contract_kind,
                        contract_id: contract_id,
                        provider_version: options[:provider_version],
                        provider_build_hash: options[:provider_build_hash]
                      )
                      raise proof_errors.join("\n") unless proof_errors.empty?
                      options[:fixture_names].each do |name|
                        raise "#{contract_kind} fixture-name must end with .json" unless name.to_s.end_with?(".json")
                      end
                      expected_fixture_name = default_fixture_name(contract_kind, options[:event], contract_id, sources.first, 0, 1)
                      if !options[:fixture_names].empty? && options[:fixture_names].fetch(0) != expected_fixture_name
                        raise "#{contract_kind} fixture-name must be #{expected_fixture_name.inspect} for typed contract proofs"
                      end
                      contract_component = StrictModeFixtures.safe_component(contract_id)
                      event_component = StrictModeFixtures.safe_component(options[:event])
                      extra_fixture_sources = []
                      case contract_kind
                      when "command-execution"
                        raise "command-execution proofs require exactly one --discovery-record" unless options[:discovery_records].length == 1
                        %i[stdout stderr exit_code].each do |field|
                          raise "command-execution proofs require --#{field.to_s.tr("_", "-")}" unless options[field]
                        end
                        discovery_source = source_file(options[:discovery_records].first)
                        stdout_source = source_file(options[:stdout])
                        stderr_source = source_file(options[:stderr])
                        exit_code_source = source_file(options[:exit_code])
                        validate_command_execution_sources!(
                          options[:root],
                          provider,
                          options[:event],
                          typed_contract_proof,
                          discovery_source,
                          stdout_source,
                          stderr_source,
                          exit_code_source,
                          "#{contract_id}.command-execution"
                        )
                        extra_fixture_sources = [
                          ["command-execution/#{event_component}/#{contract_component}.discovery-record.json", discovery_source],
                          ["command-execution/#{event_component}/#{contract_component}.stdout", stdout_source],
                          ["command-execution/#{event_component}/#{contract_component}.stderr", stderr_source],
                          ["command-execution/#{event_component}/#{contract_component}.exit-code", exit_code_source]
                        ]
                      when "matcher"
                        raise "matcher proofs require exactly one --discovery-record" unless options[:discovery_records].length == 1
                        discovery_source = source_file(options[:discovery_records].first)
                        validate_matcher_discovery_source_binding!(
                          options[:root],
                          provider,
                          options[:event],
                          typed_contract_proof,
                          discovery_source,
                          "#{contract_id}.matcher"
                        )
                        extra_fixture_sources = [["matcher/#{event_component}/#{contract_component}.discovery-record.json", discovery_source]]
                      when "event-order"
                        raise "event-order proofs require at least one --discovery-record" if options[:discovery_records].empty?
                        discovery_sources = options[:discovery_records].map { |path| source_file(path) }
                        discovery_records = validate_event_order_sources!(
                          options[:root],
                          provider,
                          typed_contract_proof,
                          discovery_sources,
                          "#{contract_id}.event-order"
                        )
                        extra_fixture_sources = discovery_records.each_with_index.map do |(discovery_source, discovery), index|
                          discovery_event = StrictModeFixtures.safe_component(discovery.fetch("event"))
                          suffix = "#{index + 1}-#{discovery_event}"
                          ["event-order/#{event_component}/#{contract_component}.#{suffix}.discovery-record.json", discovery_source]
                        end
                      end
                      fixture_sources = [[expected_fixture_name, sources.first]] + extra_fixture_sources
                      preflight_fixture_writes!(options[:root], provider, fixture_sources, options[:replace])
                      fixture_sources.each do |fixture_name, source|
                        fixture_paths << copy_fixture!(options[:root], provider, fixture_name, source, options[:replace])
                      end
                    else
                      fixture_sources = sources.each_with_index.map do |source, index|
                        fixture_name = options[:fixture_names][index] || default_fixture_name(contract_kind, options[:event], contract_id, source, index, sources.length)
                        [fixture_name, source]
                      end
                      preflight_fixture_writes!(options[:root], provider, fixture_sources, options[:replace])
                      fixture_paths = fixture_sources.map do |fixture_name, source|
                        copy_fixture!(options[:root], provider, fixture_name, source, options[:replace])
                      end
                    end
                    fixture_paths
                  end

  fixture_file_hashes = fixture_paths.map { |path| fixture_hash_entry(options[:root], path) }.sort_by { |item| item.fetch("path") }
  surface_hash = if typed_contract_proof && contract_kind == "command-execution"
                   StrictModeFixtures.typed_contract_proof_hash(
                     {
                       "contract_kind" => contract_kind,
                       "provider" => provider,
                       "event" => options[:event],
                       "contract_id" => contract_id
                     },
                     typed_contract_proof
                   )
                 else
                   Digest::SHA256.hexdigest(JSON.generate(fixture_file_hashes))
                 end
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
