#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "time"
require_relative "metadata_lib"

module StrictModeFixtures
  extend self

  ZERO_HASH = "0" * 64
  PROVIDERS = %w[claude codex].freeze
  CONTRACT_KINDS = %w[
    payload-schema
    matcher
    command-execution
    event-order
    prompt-extraction
    judge-invocation
    worker-invocation
    decision-output
    version-comparator
  ].freeze
  COMPATIBILITY_MODES = %w[exact range unknown-only].freeze
  MANIFEST_FIELDS = %w[schema_version generated_at records manifest_hash].freeze
  RECORD_FIELDS = %w[
    schema_version
    contract_id
    provider
    provider_version
    provider_build_hash
    platform
    event
    contract_kind
    payload_schema_hash
    decision_contract_hash
    command_execution_contract_hash
    fixture_file_hashes
    captured_at
    compatibility_range
    fixture_record_hash
  ].freeze
  FIXTURE_FILE_FIELDS = %w[path content_sha256].freeze
  COMPATIBILITY_FIELDS = %w[mode min_version max_version version_comparator provider_build_hashes].freeze
  CONTRACT_ID_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
  SHA256_PATTERN = /\A[a-f0-9]{64}\z/

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def project_root
    StrictModeMetadata.project_root
  end

  def provider_fixture_dir(root, provider)
    Pathname.new(root).join("providers/#{provider}/fixtures")
  end

  def manifest_path(root, provider)
    provider_fixture_dir(root, provider).join("fixture-manifest.json")
  end

  def provider_list(value)
    case value
    when "claude", "codex"
      [value]
    when "all"
      PROVIDERS
    else
      raise ArgumentError, "provider must be claude, codex, or all"
    end
  end

  def empty_manifest(generated_at = "1970-01-01T00:00:00Z")
    {
      "schema_version" => 1,
      "generated_at" => generated_at,
      "records" => [],
      "manifest_hash" => ""
    }
  end

  def hash_record(record, field)
    clone = JSON.parse(JSON.generate(record))
    clone[field] = ""
    StrictModeMetadata.hash_record(clone, field)
  end

  def safe_component(value)
    component = value.to_s.downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/\A[._-]+|[._-]+\z/, "")
    raise ArgumentError, "value does not produce a safe fixture path component" if component.empty?

    component
  end

  def json_shape(value)
    case value
    when Hash
      {
        "type" => "object",
        "fields" => value.keys.sort.each_with_object({}) { |key, fields| fields[key] = json_shape(value.fetch(key)) }
      }
    when Array
      item_shapes = value.map { |item| json_shape(item) }
      {
        "type" => "array",
        "items" => item_shapes.uniq.sort_by { |item| StrictModeMetadata.canonical_json(item) }
      }
    when String
      { "type" => "string" }
    when Integer
      { "type" => "integer" }
    when Float
      { "type" => "number" }
    when true, false
      { "type" => "boolean" }
    when nil
      { "type" => "null" }
    else
      raise "unsupported JSON value in payload shape: #{value.class}"
    end
  end

  def payload_schema_hash(provider, event, parsed_payload, normalized_event, provider_proof)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "schema_version" => 1,
      "kind" => "discovered-json-shape-plus-normalized-event",
      "provider" => provider,
      "event" => event,
      "shape" => json_shape(parsed_payload),
      "normalized_event_sha256" => Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(normalized_event)),
      "provider_proof_sha256" => Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(provider_proof))
    }))
  end

  def normalize_manifest_hashes(manifest)
    normalized = JSON.parse(JSON.generate(manifest))
    if normalized["records"].is_a?(Array)
      normalized["records"].each do |record|
        record["fixture_record_hash"] = hash_record(record, "fixture_record_hash") if record.is_a?(Hash)
      end
    end
    normalized["manifest_hash"] = hash_record(normalized, "manifest_hash")
    normalized
  end

  def write_manifest(path, manifest)
    StrictModeMetadata.write_json(path, normalize_manifest_hashes(manifest))
  end

  def load_json(path)
    record = JSON.parse(Pathname.new(path).read, object_class: DuplicateKeyHash)
    raise "#{path}: JSON root must be an object" unless record.is_a?(Hash)

    JSON.parse(JSON.generate(record))
  rescue JSON::ParserError, SystemCallError, RuntimeError => e
    raise "#{path}: malformed JSON: #{e.message}"
  end

  def validate_provider_manifest(root, provider)
    root = Pathname.new(root)
    path = manifest_path(root, provider)
    errors = []
    manifest = load_json(path)
    expect(errors, path, manifest.keys.sort == MANIFEST_FIELDS.sort, "manifest fields must be exact")
    expect(errors, path, manifest["schema_version"] == 1, "schema_version must be 1")
    expect_iso8601(errors, path, manifest["generated_at"], "generated_at")
    expect(errors, path, manifest["records"].is_a?(Array), "records must be an array")
    expect_sha(errors, path, manifest["manifest_hash"], "manifest_hash")
    expect(errors, path, manifest["manifest_hash"] == hash_record(manifest, "manifest_hash"), "manifest_hash mismatch") if manifest["manifest_hash"].is_a?(String)
    return errors unless manifest["records"].is_a?(Array)

    contract_ids = []
    comparator_ids = []
    manifest["records"].each_with_index do |record, index|
      validate_record(errors, root, path, provider, record, index)
      contract_ids << record["contract_id"] if record.is_a?(Hash)
      if record.is_a?(Hash) && record.dig("compatibility_range", "mode") == "range"
        comparator_ids << record.dig("compatibility_range", "version_comparator")
      end
    end
    expect(errors, path, contract_ids == contract_ids.uniq, "contract_id values must be unique")
    comparator_ids.compact.reject(&:empty?).each do |contract_id|
      comparator = manifest["records"].find { |record| record.is_a?(Hash) && record["contract_id"] == contract_id }
      expect(errors, path, comparator && comparator["contract_kind"] == "version-comparator", "range compatibility comparator #{contract_id.inspect} must reference a version-comparator record")
    end
    errors
  rescue RuntimeError => e
    ["#{path}: #{e.message}"]
  end

  def validate_record(errors, root, manifest_path, provider, record, index)
    unless record.is_a?(Hash)
      errors << "#{manifest_path}: records[#{index}] must be an object"
      return
    end

    expect(errors, manifest_path, record.keys.sort == RECORD_FIELDS.sort, "records[#{index}] fields must be exact")
    expect(errors, manifest_path, record["schema_version"] == 1, "records[#{index}].schema_version must be 1")
    expect(errors, manifest_path, record["contract_id"].is_a?(String) && record["contract_id"].match?(CONTRACT_ID_PATTERN), "records[#{index}].contract_id must be a stable lowercase id")
    expect(errors, manifest_path, record["provider"] == provider, "records[#{index}].provider must match manifest provider")
    expect(errors, manifest_path, PROVIDERS.include?(record["provider"]), "records[#{index}].provider must be claude or codex")
    expect(errors, manifest_path, record["provider_version"].is_a?(String) && !record["provider_version"].empty?, "records[#{index}].provider_version must be a non-empty string")
    expect(errors, manifest_path, record["provider_build_hash"] == "" || sha?(record["provider_build_hash"]), "records[#{index}].provider_build_hash must be empty or lowercase SHA-256")
    expect(errors, manifest_path, record["platform"].is_a?(String) && !record["platform"].empty?, "records[#{index}].platform must be a non-empty string")
    expect(errors, manifest_path, record["event"].is_a?(String) && !record["event"].empty?, "records[#{index}].event must be a non-empty string")
    expect(errors, manifest_path, CONTRACT_KINDS.include?(record["contract_kind"]), "records[#{index}].contract_kind must be a closed fixture contract kind")
    expect_sha(errors, manifest_path, record["payload_schema_hash"], "records[#{index}].payload_schema_hash")
    expect_sha(errors, manifest_path, record["decision_contract_hash"], "records[#{index}].decision_contract_hash")
    expect_sha(errors, manifest_path, record["command_execution_contract_hash"], "records[#{index}].command_execution_contract_hash")
    validate_contract_hash_sentinels(errors, manifest_path, record, index)
    validate_fixture_file_hashes(errors, root, manifest_path, record, index)
    validate_payload_schema_fixture(errors, root, manifest_path, record, index) if record["contract_kind"] == "payload-schema"
    validate_decision_output_fixture(errors, root, manifest_path, record, index) if record["contract_kind"] == "decision-output"
    expect_iso8601(errors, manifest_path, record["captured_at"], "records[#{index}].captured_at")
    validate_compatibility(errors, manifest_path, record, index)
    expect_sha(errors, manifest_path, record["fixture_record_hash"], "records[#{index}].fixture_record_hash")
    expect(errors, manifest_path, record["fixture_record_hash"] == hash_record(record, "fixture_record_hash"), "records[#{index}].fixture_record_hash mismatch") if record["fixture_record_hash"].is_a?(String)
  end

  def validate_contract_hash_sentinels(errors, path, record, index)
    kind = record["contract_kind"]
    required = case kind
               when "payload-schema", "prompt-extraction"
                 %w[payload_schema_hash]
               when "command-execution"
                 %w[command_execution_contract_hash]
               when "decision-output"
                 %w[decision_contract_hash]
               when "judge-invocation", "worker-invocation"
                 %w[decision_contract_hash command_execution_contract_hash]
               else
                 []
               end
    %w[payload_schema_hash decision_contract_hash command_execution_contract_hash].each do |field|
      if required.include?(field)
        expect(errors, path, record[field].is_a?(String) && record[field].match?(SHA256_PATTERN) && record[field] != ZERO_HASH, "records[#{index}].#{field} must be populated for #{kind}")
      else
        expect(errors, path, record[field] == ZERO_HASH, "records[#{index}].#{field} must be zero sentinel for #{kind}")
      end
    end
  end

  def validate_fixture_file_hashes(errors, root, manifest_path, record, index)
    hashes = record["fixture_file_hashes"]
    unless hashes.is_a?(Array)
      errors << "#{manifest_path}: records[#{index}].fixture_file_hashes must be an array"
      return
    end
    expect(errors, manifest_path, !hashes.empty?, "records[#{index}].fixture_file_hashes must not be empty")

    paths = []
    hashes.each_with_index do |item, item_index|
      unless item.is_a?(Hash)
        errors << "#{manifest_path}: records[#{index}].fixture_file_hashes[#{item_index}] must be an object"
        next
      end
      expect(errors, manifest_path, item.keys.sort == FIXTURE_FILE_FIELDS.sort, "records[#{index}].fixture_file_hashes[#{item_index}] fields must be exact")
      relative = item["path"]
      paths << relative if relative.is_a?(String)
      fixture_path = fixture_path_for(root, record["provider"], relative)
      if fixture_path
        expect(errors, manifest_path, fixture_path.file? && !fixture_path.symlink?, "records[#{index}].fixture_file_hashes[#{item_index}].path must point at an existing non-symlink fixture file")
        expect(errors, manifest_path, item["content_sha256"] == Digest::SHA256.file(fixture_path).hexdigest, "records[#{index}].fixture_file_hashes[#{item_index}].content_sha256 mismatch") if fixture_path.file? && !fixture_path.symlink?
      else
        errors << "#{manifest_path}: records[#{index}].fixture_file_hashes[#{item_index}].path is not a safe repository-relative path"
      end
      expect_sha(errors, manifest_path, item["content_sha256"], "records[#{index}].fixture_file_hashes[#{item_index}].content_sha256")
    end
    expect(errors, manifest_path, paths == paths.uniq.sort, "records[#{index}].fixture_file_hashes paths must be sorted and unique")
  end

  def validate_payload_schema_fixture(errors, root, manifest_path, record, index)
    load_payload_schema_helpers
    roles = payload_schema_fixture_roles(record)
    label = "records[#{index}].payload-schema"
    expect(errors, manifest_path, roles["raw"].length == 1, "#{label} must include exactly one raw payload fixture")
    expect(errors, manifest_path, roles["normalized"].length == 1, "#{label} must include exactly one normalized event fixture")
    expect(errors, manifest_path, roles["provider_proof"].length == 1, "#{label} must include exactly one provider proof fixture")
    expect(errors, manifest_path, roles["other"].empty?, "#{label} must not include extra fixture files")
    return unless roles["raw"].length == 1 && roles["normalized"].length == 1 && roles["provider_proof"].length == 1 && roles["other"].empty?

    raw_path = fixture_path_for(root, record["provider"], roles["raw"].first)
    normalized_path = fixture_path_for(root, record["provider"], roles["normalized"].first)
    provider_proof_path = fixture_path_for(root, record["provider"], roles["provider_proof"].first)
    return unless safe_fixture_file?(raw_path) && safe_fixture_file?(normalized_path) && safe_fixture_file?(provider_proof_path)

    raw_payload = load_fixture_json(errors, manifest_path, raw_path, "#{label}.raw_payload")
    normalized_event = load_fixture_json(errors, manifest_path, normalized_path, "#{label}.normalized_event")
    provider_proof = load_fixture_json(errors, manifest_path, provider_proof_path, "#{label}.provider_proof")
    return unless raw_payload.is_a?(Hash) && normalized_event.is_a?(Hash) && provider_proof.is_a?(Hash)

    raw_hash = Digest::SHA256.file(raw_path).hexdigest
    normalized_errors = StrictModeNormalized.validate(normalized_event)
    normalized_errors.each { |message| errors << "#{manifest_path}: #{label}.normalized_event #{message}" }
    proof_errors = StrictModeProviderDetection.validate(provider_proof)
    proof_errors.each { |message| errors << "#{manifest_path}: #{label}.provider_proof #{message}" }
    expect(errors, manifest_path, normalized_event["provider"] == record["provider"], "#{label}.normalized_event provider must match record provider")
    expect(errors, manifest_path, normalized_event["logical_event"] == record["event"], "#{label}.normalized_event logical_event must match record event")
    expect(errors, manifest_path, normalized_event.dig("raw", "payload_sha256") == raw_hash, "#{label}.normalized_event raw payload hash must match raw fixture")
    expect(errors, manifest_path, provider_proof["provider_arg"] == record["provider"], "#{label}.provider_proof provider_arg must match record provider")
    expect(errors, manifest_path, provider_proof["payload_sha256"] == raw_hash, "#{label}.provider_proof payload hash must match raw fixture")
    expect(errors, manifest_path, provider_proof["decision"] == "match", "#{label}.provider_proof decision must be match")
    if normalized_errors.empty?
      expected_normalized = begin
        StrictModeNormalized.normalize(
          raw_payload,
          provider: record["provider"],
          logical_event: record["event"],
          cwd: normalized_event.fetch("cwd"),
          project_dir: normalized_event.fetch("project_dir"),
          payload_sha256: raw_hash
        )
      rescue RuntimeError, ArgumentError => e
        errors << "#{manifest_path}: #{label}.normalized_event cannot be regenerated from raw payload: #{e.message}"
        nil
      end
      if expected_normalized
        expect(errors, manifest_path, StrictModeMetadata.canonical_json(normalized_event) == StrictModeMetadata.canonical_json(expected_normalized), "#{label}.normalized_event must match raw payload normalization")
      end
    end
    if proof_errors.empty?
      expected_proof = begin
        StrictModeProviderDetection.proof(
          raw_payload,
          provider_arg: record["provider"],
          provider_arg_source: provider_proof.fetch("provider_arg_source"),
          payload_sha256: raw_hash
        )
      rescue RuntimeError, ArgumentError => e
        errors << "#{manifest_path}: #{label}.provider_proof cannot be regenerated from raw payload: #{e.message}"
        nil
      end
      if expected_proof
        expect(errors, manifest_path, StrictModeMetadata.canonical_json(provider_proof) == StrictModeMetadata.canonical_json(expected_proof), "#{label}.provider_proof must match raw payload detection")
      end
    end
    expected_hash = payload_schema_hash(record["provider"], record["event"], raw_payload, normalized_event, provider_proof)
    expect(errors, manifest_path, record["payload_schema_hash"] == expected_hash, "#{label}.payload_schema_hash must bind raw shape, normalized event, and provider proof")
  end

  def load_payload_schema_helpers
    require_relative "normalized_event_lib" unless defined?(StrictModeNormalized)
    require_relative "provider_detection_lib" unless defined?(StrictModeProviderDetection)
  end

  def validate_decision_output_fixture(errors, root, manifest_path, record, index)
    load_decision_contract_helpers
    roles = decision_output_fixture_roles(record)
    label = "records[#{index}].decision-output"
    expect(errors, manifest_path, roles["metadata"].length == 1, "#{label} must include exactly one provider output metadata fixture")
    expect(errors, manifest_path, roles["stdout"].length == 1, "#{label} must include exactly one stdout fixture")
    expect(errors, manifest_path, roles["stderr"].length == 1, "#{label} must include exactly one stderr fixture")
    expect(errors, manifest_path, roles["exit_code"].length == 1, "#{label} must include exactly one exit-code fixture")
    expect(errors, manifest_path, roles["other"].empty?, "#{label} must not include extra fixture files")
    return unless roles["metadata"].length == 1 && roles["stdout"].length == 1 && roles["stderr"].length == 1 && roles["exit_code"].length == 1 && roles["other"].empty?

    metadata_path = fixture_path_for(root, record["provider"], roles["metadata"].first)
    stdout_path = fixture_path_for(root, record["provider"], roles["stdout"].first)
    stderr_path = fixture_path_for(root, record["provider"], roles["stderr"].first)
    exit_code_path = fixture_path_for(root, record["provider"], roles["exit_code"].first)
    return unless safe_fixture_file?(metadata_path) && safe_fixture_file?(stdout_path) && safe_fixture_file?(stderr_path) && safe_fixture_file?(exit_code_path)

    metadata = load_fixture_json(errors, manifest_path, metadata_path, "#{label}.provider_output")
    return unless metadata.is_a?(Hash)

    metadata_errors = StrictModeDecisionContract.validate_provider_output(metadata)
    metadata_errors.each { |message| errors << "#{manifest_path}: #{label}.provider_output #{message}" }
    expect(errors, manifest_path, metadata["contract_id"] == record["contract_id"], "#{label}.provider_output contract_id must match fixture record")
    expect(errors, manifest_path, metadata["provider"] == record["provider"], "#{label}.provider_output provider must match fixture record")
    expect(errors, manifest_path, metadata["event"] == record["event"], "#{label}.provider_output event must match fixture record event")
    expect(errors, manifest_path, metadata["logical_event"] == record["event"], "#{label}.provider_output logical_event must match fixture record event")
    expect(errors, manifest_path, record["decision_contract_hash"] == metadata["decision_contract_hash"], "#{label}.decision_contract_hash must match provider output metadata")
    exit_code = parse_exit_code_fixture(errors, manifest_path, exit_code_path, label)
    if metadata_errors.empty? && exit_code
      capture_errors = StrictModeDecisionContract.validate_captured_output(
        metadata,
        stdout_bytes: stdout_path.binread,
        stderr_bytes: stderr_path.binread,
        exit_code: exit_code
      )
      capture_errors.each { |message| errors << "#{manifest_path}: #{label} #{message}" }
    end
  end

  def load_decision_contract_helpers
    require_relative "decision_contract_lib" unless defined?(StrictModeDecisionContract)
  end

  def decision_output_fixture_roles(record)
    provider = record["provider"].to_s
    event_component = safe_component(record["event"])
    contract_component = safe_component(record["contract_id"])
    prefix = "providers/#{provider}/fixtures/decision-output/#{event_component}/"
    roles = {
      "metadata" => [],
      "stdout" => [],
      "stderr" => [],
      "exit_code" => [],
      "other" => []
    }
    Array(record["fixture_file_hashes"]).each do |item|
      path = item.is_a?(Hash) ? item["path"].to_s : ""
      if path == "#{prefix}#{contract_component}.provider-output.json"
        roles["metadata"] << path
      elsif path == "#{prefix}#{contract_component}.stdout"
        roles["stdout"] << path
      elsif path == "#{prefix}#{contract_component}.stderr"
        roles["stderr"] << path
      elsif path == "#{prefix}#{contract_component}.exit-code"
        roles["exit_code"] << path
      else
        roles["other"] << path
      end
    end
    roles
  rescue ArgumentError
    {
      "metadata" => [],
      "stdout" => [],
      "stderr" => [],
      "exit_code" => [],
      "other" => Array(record["fixture_file_hashes"]).map { |item| item.is_a?(Hash) ? item["path"].to_s : "" }
    }
  end

  def parse_exit_code_fixture(errors, manifest_path, path, label)
    text = path.read
    unless text.match?(/\A(?:0|[1-9][0-9]{0,2})\n?\z/)
      errors << "#{manifest_path}: #{label}.exit_code must contain one integer"
      return nil
    end
    value = text.to_i
    unless value.between?(0, 255)
      errors << "#{manifest_path}: #{label}.exit_code must be integer 0..255"
      return nil
    end
    value
  rescue SystemCallError => e
    errors << "#{manifest_path}: #{label}.exit_code could not be read: #{e.message}"
    nil
  end

  def payload_schema_fixture_roles(record)
    provider = record["provider"].to_s
    event_component = safe_component(record["event"])
    prefix = "providers/#{provider}/fixtures/"
    raw_prefix = "#{prefix}payloads/#{event_component}/"
    normalized_prefix = "#{prefix}normalized/#{event_component}/"
    provider_proof_prefix = "#{prefix}provider-proof/#{event_component}/"
    roles = {
      "raw" => [],
      "normalized" => [],
      "provider_proof" => [],
      "other" => []
    }
    Array(record["fixture_file_hashes"]).each do |item|
      path = item.is_a?(Hash) ? item["path"].to_s : ""
      if path.start_with?(raw_prefix) && path.end_with?(".json") && !path.end_with?(".event.normalized.json") && !path.end_with?(".provider-detection.json")
        roles["raw"] << path
      elsif path.start_with?(normalized_prefix) && path.end_with?(".event.normalized.json")
        roles["normalized"] << path
      elsif path.start_with?(provider_proof_prefix) && path.end_with?(".provider-detection.json")
        roles["provider_proof"] << path
      else
        roles["other"] << path
      end
    end
    roles
  rescue ArgumentError
    {
      "raw" => [],
      "normalized" => [],
      "provider_proof" => [],
      "other" => Array(record["fixture_file_hashes"]).map { |item| item.is_a?(Hash) ? item["path"].to_s : "" }
    }
  end

  def load_fixture_json(errors, manifest_path, path, label)
    record = JSON.parse(path.read, object_class: DuplicateKeyHash)
    unless record.is_a?(Hash)
      errors << "#{manifest_path}: #{label} must be a JSON object"
      return nil
    end

    JSON.parse(JSON.generate(record))
  rescue JSON::ParserError, SystemCallError, RuntimeError => e
    errors << "#{manifest_path}: #{label} must be duplicate-key-safe JSON: #{e.message}"
    nil
  end

  def safe_fixture_file?(path)
    path&.file? && !path.symlink?
  end

  def fixture_path_for(root, provider, relative)
    return nil unless relative.is_a?(String)
    return nil if relative.empty? || relative.start_with?("/") || relative.match?(/[\0\n\r]/)

    clean = Pathname.new(relative).cleanpath
    return nil if clean.to_s.start_with?("../") || clean.to_s == ".."
    return nil unless clean.to_s.start_with?("providers/#{provider}/fixtures/")
    return nil if path_has_symlink_parent_component?(root, clean)

    root.join(clean)
  end

  def path_has_symlink_parent_component?(root, relative)
    current = Pathname.new(root)
    parts = relative.each_filename.to_a
    parts[0...-1].any? do |part|
      current = current.join(part)
      current.symlink?
    end
  end

  def validate_compatibility(errors, path, record, index)
    compatibility = record["compatibility_range"]
    unless compatibility.is_a?(Hash)
      errors << "#{path}: records[#{index}].compatibility_range must be an object"
      return
    end

    expect(errors, path, compatibility.keys.sort == COMPATIBILITY_FIELDS.sort, "records[#{index}].compatibility_range fields must be exact")
    mode = compatibility["mode"]
    expect(errors, path, COMPATIBILITY_MODES.include?(mode), "records[#{index}].compatibility_range.mode must be exact, range, or unknown-only")
    expect(errors, path, compatibility["provider_build_hashes"].is_a?(Array) && compatibility["provider_build_hashes"].all? { |item| sha?(item) }, "records[#{index}].compatibility_range.provider_build_hashes must be SHA-256 array")
    expect(errors, path, compatibility["provider_build_hashes"] == compatibility["provider_build_hashes"].uniq.sort, "records[#{index}].compatibility_range.provider_build_hashes must be sorted and unique") if compatibility["provider_build_hashes"].is_a?(Array)
    case mode
    when "exact"
      expect(errors, path, record["provider_version"] != "unknown", "records[#{index}].exact compatibility requires known provider_version")
      expect(errors, path, compatibility["min_version"] == record["provider_version"], "records[#{index}].exact min_version must equal provider_version")
      expect(errors, path, compatibility["max_version"] == record["provider_version"], "records[#{index}].exact max_version must equal provider_version")
      expect(errors, path, compatibility["version_comparator"] == "", "records[#{index}].exact version_comparator must be empty")
    when "unknown-only"
      expect(errors, path, record["provider_version"] == "unknown", "records[#{index}].unknown-only requires provider_version=unknown")
      expect(errors, path, compatibility["min_version"] == "unknown", "records[#{index}].unknown-only min_version must be unknown")
      expect(errors, path, compatibility["max_version"] == "unknown", "records[#{index}].unknown-only max_version must be unknown")
      expect(errors, path, compatibility["version_comparator"] == "", "records[#{index}].unknown-only version_comparator must be empty")
      expect(errors, path, compatibility["provider_build_hashes"].empty?, "records[#{index}].unknown-only provider_build_hashes must be empty") if compatibility["provider_build_hashes"].is_a?(Array)
    when "range"
      expect(errors, path, compatibility["min_version"].is_a?(String) && !compatibility["min_version"].empty? && compatibility["min_version"] != "unknown", "records[#{index}].range min_version must be concrete")
      expect(errors, path, compatibility["max_version"].is_a?(String) && !compatibility["max_version"].empty? && compatibility["max_version"] != "unknown", "records[#{index}].range max_version must be concrete")
      expect(errors, path, compatibility["version_comparator"].is_a?(String) && compatibility["version_comparator"].match?(CONTRACT_ID_PATTERN), "records[#{index}].range version_comparator must name a contract id")
    end
  end

  def expect_iso8601(errors, path, value, field)
    unless value.is_a?(String)
      errors << "#{path}: #{field} must be an ISO-8601 timestamp"
      return
    end
    Time.iso8601(value)
  rescue ArgumentError
    errors << "#{path}: #{field} must be an ISO-8601 timestamp"
  end

  def expect_sha(errors, path, value, field)
    expect(errors, path, sha?(value), "#{field} must be lowercase SHA-256")
  end

  def sha?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end

  def expect(errors, path, condition, message)
    errors << "#{path}: #{message}" unless condition
  end
end
