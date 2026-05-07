#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require_relative "fixture_manifest_lib"
require_relative "normalized_event_lib"

module StrictModeDecisionContract
  extend self

  INTERNAL_FIELDS = %w[
    schema_version
    action
    reason
    severity
    additional_context
    metadata
  ].freeze
  INTERNAL_ACTIONS = %w[allow block warn inject].freeze
  INTERNAL_SEVERITIES = %w[info warning error critical].freeze
  PROVIDER_OUTPUT_FIELDS = %w[
    schema_version
    contract_id
    provider
    event
    logical_event
    provider_action
    stdout_mode
    stdout_required_fields
    stderr_mode
    stderr_required_fields
    exit_code
    blocks_or_denies
    injects_context
    decision_contract_hash
  ].freeze
  PROVIDER_ACTIONS = %w[allow block deny warn inject no-op].freeze
  OUTPUT_MODES = %w[empty plain-text json provider-native-json].freeze
  SHA256_PATTERN = /\A[a-f0-9]{64}\z/
  UNSAFE_METADATA_KEY_PATTERN = /(raw|prompt|payload|transcript|history|content|source|secret|token|password|passwd|api[_-]?key|private[_-]?key|access[_-]?key)/i
  UNSAFE_METADATA_VALUE_PATTERNS = [
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    /\bsk-[A-Za-z0-9_-]{16,}/,
    /\bgh[pousr]_[A-Za-z0-9_]{16,}/,
    /\bAKIA[0-9A-Z]{16}\b/,
    /\b(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+/i
  ].freeze

  def load_json(path)
    record = JSON.parse(Pathname.new(path).read, object_class: StrictModeFixtures::DuplicateKeyHash)
    raise "#{path}: JSON root must be an object" unless record.is_a?(Hash)

    JSON.parse(JSON.generate(record))
  rescue JSON::ParserError, SystemCallError, RuntimeError => e
    raise "#{path}: malformed JSON: #{e.message}"
  end

  def validate_internal(record)
    errors = []
    unless record.is_a?(Hash)
      return ["internal decision must be an object"]
    end

    expect(errors, record.keys.sort == INTERNAL_FIELDS.sort, "internal decision fields must be exact")
    expect(errors, record["schema_version"] == 1, "schema_version must be 1")
    expect_in(errors, record["action"], INTERNAL_ACTIONS, "action")
    expect_in(errors, record["severity"], INTERNAL_SEVERITIES, "severity")
    expect_string(errors, record["reason"], "reason")
    expect_string(errors, record["additional_context"], "additional_context")
    expect(errors, record["metadata"].is_a?(Hash), "metadata must be an object")
    validate_metadata(errors, record["metadata"], "metadata") if record["metadata"].is_a?(Hash)
    validate_action_text(errors, record)
    errors
  end

  def validate_action_text(errors, record)
    action = record["action"]
    reason = record["reason"]
    additional_context = record["additional_context"]
    severity = record["severity"]
    return unless action.is_a?(String) && reason.is_a?(String) && additional_context.is_a?(String)

    case action
    when "allow"
      expect(errors, reason.empty?, "allow reason must be empty")
      expect(errors, additional_context.empty?, "allow additional_context must be empty")
      expect(errors, severity == "info", "allow severity must be info")
    when "warn"
      expect(errors, !reason.empty?, "warn reason must be non-empty")
      expect(errors, severity == "warning", "warn severity must be warning")
    when "block"
      expect(errors, !reason.empty?, "block reason must be non-empty")
      expect(errors, %w[error critical].include?(severity), "block severity must be error or critical")
    when "inject"
      expect(errors, !additional_context.empty?, "inject additional_context must be non-empty")
      expect(errors, reason.empty?, "inject reason must be empty")
      expect(errors, severity == "info", "inject severity must be info")
    end
  end

  def validate_metadata(errors, value, path)
    case value
    when Hash
      value.each do |key, nested|
        unless key.is_a?(String)
          errors << "#{path} keys must be strings"
          next
        end
        errors << "#{path}.#{key} uses unsafe metadata key" if key.match?(UNSAFE_METADATA_KEY_PATTERN)
        validate_metadata(errors, nested, "#{path}.#{key}")
      end
    when Array
      value.each_with_index { |nested, index| validate_metadata(errors, nested, "#{path}[#{index}]") }
    when String
      errors << "#{path} string is too large" if value.bytesize > 4096
      errors << "#{path} contains secret-like content" if UNSAFE_METADATA_VALUE_PATTERNS.any? { |pattern| value.match?(pattern) }
    when Integer, true, false, nil
      # safe JSON primitive
    else
      errors << "#{path} contains unsupported metadata value #{value.class}"
    end
  end

  def provider_output_hash(record)
    clone = JSON.parse(JSON.generate(record))
    clone["decision_contract_hash"] = ""
    StrictModeMetadata.hash_record(clone, "decision_contract_hash")
  end

  def validate_provider_output(record)
    errors = []
    unless record.is_a?(Hash)
      return ["provider output metadata must be an object"]
    end

    expect(errors, record.keys.sort == PROVIDER_OUTPUT_FIELDS.sort, "provider output metadata fields must be exact")
    expect(errors, record["schema_version"] == 1, "schema_version must be 1")
    expect(errors, record["contract_id"].is_a?(String) && record["contract_id"].match?(StrictModeFixtures::CONTRACT_ID_PATTERN), "contract_id must be a stable lowercase id")
    expect_in(errors, record["provider"], StrictModeFixtures::PROVIDERS, "provider")
    expect(errors, record["event"].is_a?(String) && !record["event"].empty?, "event must be a non-empty string")
    expect_in(errors, record["logical_event"], StrictModeNormalized::LOGICAL_EVENTS, "logical_event")
    expect_in(errors, record["provider_action"], PROVIDER_ACTIONS, "provider_action")
    expect_in(errors, record["stdout_mode"], OUTPUT_MODES, "stdout_mode")
    expect_sorted_string_array(errors, record["stdout_required_fields"], "stdout_required_fields")
    expect_in(errors, record["stderr_mode"], OUTPUT_MODES, "stderr_mode")
    expect_sorted_string_array(errors, record["stderr_required_fields"], "stderr_required_fields")
    expect(errors, record["exit_code"].is_a?(Integer) && record["exit_code"].between?(0, 255), "exit_code must be integer 0..255")
    expect_in(errors, record["blocks_or_denies"], [0, 1], "blocks_or_denies")
    expect_in(errors, record["injects_context"], [0, 1], "injects_context")
    expect_sha(errors, record["decision_contract_hash"], "decision_contract_hash")
    validate_mode_fields(errors, record, "stdout")
    validate_mode_fields(errors, record, "stderr")
    if %w[block deny].include?(record["provider_action"])
      expect(errors, record["blocks_or_denies"] == 1, "block or deny provider_action requires blocks_or_denies=1")
    else
      expect(errors, record["blocks_or_denies"] == 0, "non-block/deny provider_action requires blocks_or_denies=0")
    end
    if record["provider_action"] == "inject"
      expect(errors, record["injects_context"] == 1, "inject provider_action requires injects_context=1")
    else
      expect(errors, record["injects_context"] == 0, "non-inject provider_action requires injects_context=0")
    end
    validate_effectful_metadata(errors, record)
    if record["decision_contract_hash"].is_a?(String)
      expect(errors, record["decision_contract_hash"] == provider_output_hash(record), "decision_contract_hash mismatch")
    end
    errors
  end

  def validate_effectful_metadata(errors, record)
    action = record["provider_action"]
    return unless action.is_a?(String)

    output_mode_present = %w[stdout stderr].any? { |stream| stream_mode_can_emit?(record, stream) }
    case action
    when "block", "deny"
      exit_code = record["exit_code"]
      expect(errors, output_mode_present || (exit_code.is_a?(Integer) && !exit_code.zero?), "block/deny provider_action requires a non-empty output mode or non-zero exit_code")
    when "inject"
      expect(errors, output_mode_present, "inject provider_action requires a non-empty output mode")
    end
  end

  def stream_mode_can_emit?(record, stream)
    %w[plain-text json provider-native-json].include?(record["#{stream}_mode"])
  end

  def validate_mode_fields(errors, record, stream)
    mode = record["#{stream}_mode"]
    fields = record["#{stream}_required_fields"]
    return unless fields.is_a?(Array)

    if %w[json provider-native-json].include?(mode)
      expect(errors, fields.all? { |field| field.match?(/\A[A-Za-z0-9_.-]+\z/) }, "#{stream}_required_fields must contain provider field names")
    else
      expect(errors, fields.empty?, "#{stream}_required_fields must be empty unless #{stream}_mode is JSON")
    end
  end

  def validate_captured_output(metadata, stdout_bytes:, stderr_bytes:, exit_code:)
    errors = validate_provider_output(metadata)
    return errors unless errors.empty?

    validate_stream_capture(errors, metadata, "stdout", stdout_bytes)
    validate_stream_capture(errors, metadata, "stderr", stderr_bytes)
    unless exit_code.is_a?(Integer)
      errors << "captured exit_code must be an integer"
      return errors
    end

    expect(errors, exit_code == metadata.fetch("exit_code"), "captured exit_code must match provider output metadata")
    validate_effectful_capture(errors, metadata, stdout_bytes, stderr_bytes, exit_code)
    errors
  end

  def validate_effectful_capture(errors, metadata, stdout_bytes, stderr_bytes, exit_code)
    output_bytes_present = !stdout_bytes.empty? || !stderr_bytes.empty?
    case metadata.fetch("provider_action")
    when "block", "deny"
      expect(errors, output_bytes_present || !exit_code.zero?, "captured block/deny output must contain stdout/stderr bytes or use non-zero exit_code")
    when "inject"
      expect(errors, output_bytes_present, "captured inject output must contain stdout/stderr bytes")
    end
  end

  def validate_stream_capture(errors, metadata, stream, bytes)
    mode = metadata.fetch("#{stream}_mode")
    required_fields = metadata.fetch("#{stream}_required_fields")
    case mode
    when "empty"
      expect(errors, bytes.empty?, "captured #{stream} must be empty")
    when "plain-text"
      # No provider-native field validation is possible for plain text.
    when "json", "provider-native-json"
      begin
        parsed = JSON.parse(bytes, object_class: StrictModeFixtures::DuplicateKeyHash)
        unless parsed.is_a?(Hash)
          errors << "captured #{stream} JSON must be an object"
          return
        end
        required_fields.each do |field|
          errors << "captured #{stream} JSON missing required field #{field}" unless parsed.key?(field)
        end
      rescue JSON::ParserError => e
        errors << "captured #{stream} must be duplicate-key-safe JSON: #{e.message}"
      end
    end
  end

  def expect_sorted_string_array(errors, value, field)
    unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) } && value == value.uniq.sort
      errors << "#{field} must be a sorted unique string array"
    end
  end

  def expect_sha(errors, value, field)
    expect(errors, value.is_a?(String) && value.match?(SHA256_PATTERN), "#{field} must be lowercase SHA-256")
  end

  def expect_string(errors, value, field)
    expect(errors, value.is_a?(String), "#{field} must be a string")
  end

  def expect_in(errors, value, allowed, field)
    expect(errors, allowed.include?(value), "#{field} must be one of #{allowed.join(", ")}")
  end

  def expect(errors, condition, message)
    errors << message unless condition
  end
end
