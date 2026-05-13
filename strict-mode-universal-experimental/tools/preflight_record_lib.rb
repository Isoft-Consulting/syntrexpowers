#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "metadata_lib"
require_relative "normalized_event_lib"

module StrictModePreflightRecord
  extend self

  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[a-f0-9]{64}\z/
  FIELDS = %w[
    schema_version
    attempted
    trusted
    logical_event
    decision
    would_block
    reason_code
    reason_hash
    tool_kind
    tool_write_intent
    tool_name_hash
    command_hash
    path_list_hash
    error_count
    error_hash
    preflight_hash
  ].freeze
  DATA_HASH_FIELDS = %w[
    reason_hash
    tool_name_hash
    command_hash
    path_list_hash
    error_hash
  ].freeze
  DECISIONS = %w[allow block unknown].freeze
  LOGICAL_EVENTS = (StrictModeNormalized::LOGICAL_EVENTS + %w[unknown]).freeze
  NOT_ATTEMPTED_REASON_CODES = %w[not-applicable].freeze
  UNTRUSTED_REASON_CODES = %w[
    payload-untrusted
    provider-untrusted
    payload-truncated
    protected-baseline-untrusted
    preflight-error
  ].freeze
  CLASSIFIER_ALLOW_REASON_CODES = %w[
    shell-read-only-or-unmatched
    non-write-tool
    write-targets-disjoint
    trusted-import-ready
    destructive-confirmed
  ].freeze
  CLASSIFIER_BLOCK_REASON_CODES = %w[
    invalid-identity
    shell-command-missing
    shell-parse-error
    protected-runtime-execution
    destructive-command
    protected-root
    unknown-write-target
    protected-target-unknown
    trusted-import-invalid
    trusted-import-unavailable
    stub-detected
  ].freeze
  CLASSIFIER_REASON_CODES = (CLASSIFIER_ALLOW_REASON_CODES + CLASSIFIER_BLOCK_REASON_CODES).freeze
  REASON_CODES = (NOT_ATTEMPTED_REASON_CODES + UNTRUSTED_REASON_CODES + CLASSIFIER_REASON_CODES).freeze

  def load_json(path)
    record = JSON.parse(Pathname.new(path).read, object_class: StrictModeMetadata::DuplicateKeyHash)
    raise "#{path}: JSON root must be an object" unless record.is_a?(Hash)

    JSON.parse(JSON.generate(record))
  rescue JSON::ParserError, SystemCallError, RuntimeError => e
    raise "#{path}: malformed preflight JSON: #{e.message}"
  end

  def not_attempted(logical_event)
    with_hash(base_record(logical_event).merge("reason_code" => "not-applicable"))
  end

  def untrusted(logical_event, reason_code, errors)
    error_lines = Array(errors).map(&:to_s).reject(&:empty?)
    error_lines = ["untrusted preflight without diagnostic"] if error_lines.empty?
    with_hash(
      base_record(logical_event).merge(
        "attempted" => true,
        "reason_code" => reason_code,
        "error_count" => error_lines.length,
        "error_hash" => sha256_text(error_lines.join("\n"))
      )
    )
  end

  def trusted_from_classifier(logical_event, decision, tool)
    with_hash(
      base_record(logical_event).merge(
        "attempted" => true,
        "trusted" => true,
        "decision" => decision.fetch("decision"),
        "would_block" => decision.fetch("decision") == "block",
        "reason_code" => decision.fetch("reason_code"),
        "reason_hash" => sha256_text(decision.fetch("reason")),
        "tool_kind" => tool.fetch("kind"),
        "tool_write_intent" => tool.fetch("write_intent"),
        "tool_name_hash" => sha256_text(tool.fetch("name")),
        "command_hash" => sha256_text(tool.fetch("command")),
        "path_list_hash" => sha256_json(tool.fetch("file_paths"))
      )
    )
  end

  def trusted_allow_from_preflight(preflight, reason_code, reason)
    raise "preflight must be trusted block" unless preflight.is_a?(Hash) && preflight.fetch("trusted") == true && preflight.fetch("decision") == "block"
    raise "allow reason_code unsupported" unless CLASSIFIER_ALLOW_REASON_CODES.include?(reason_code)

    with_hash(
      preflight.merge(
        "decision" => "allow",
        "would_block" => false,
        "reason_code" => reason_code,
        "reason_hash" => sha256_text(reason),
        "error_count" => 0,
        "error_hash" => ZERO_HASH
      )
    )
  end

  def base_record(logical_event)
    normalized_logical_event = logical_event.to_s
    normalized_logical_event = "unknown" unless LOGICAL_EVENTS.include?(normalized_logical_event)
    {
      "schema_version" => 1,
      "attempted" => false,
      "trusted" => false,
      "logical_event" => normalized_logical_event,
      "decision" => "unknown",
      "would_block" => false,
      "reason_code" => "not-applicable",
      "reason_hash" => ZERO_HASH,
      "tool_kind" => "unknown",
      "tool_write_intent" => "unknown",
      "tool_name_hash" => ZERO_HASH,
      "command_hash" => ZERO_HASH,
      "path_list_hash" => ZERO_HASH,
      "error_count" => 0,
      "error_hash" => ZERO_HASH,
      "preflight_hash" => ""
    }
  end

  def with_hash(record)
    copy = JSON.parse(JSON.generate(record))
    copy["preflight_hash"] = ""
    copy["preflight_hash"] = preflight_hash(copy)
    copy
  end

  def preflight_hash(record)
    StrictModeMetadata.hash_record(record, "preflight_hash")
  end

  def sha256_text(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def sha256_json(value)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(value))
  end

  def validate(record)
    errors = []
    unless record.is_a?(Hash)
      return ["preflight record must be an object"]
    end

    expect(errors, record.keys.sort == FIELDS.sort, "preflight fields must be exact")
    expect(errors, record["schema_version"] == 1, "schema_version must be 1")
    expect_bool(errors, record["attempted"], "attempted")
    expect_bool(errors, record["trusted"], "trusted")
    expect_bool(errors, record["would_block"], "would_block")
    expect_in(errors, record["logical_event"], LOGICAL_EVENTS, "logical_event")
    expect_in(errors, record["decision"], DECISIONS, "decision")
    expect_in(errors, record["reason_code"], REASON_CODES, "reason_code")
    expect_in(errors, record["tool_kind"], StrictModeNormalized::TOOL_KINDS, "tool_kind")
    expect_in(errors, record["tool_write_intent"], StrictModeNormalized::WRITE_INTENTS, "tool_write_intent")
    (DATA_HASH_FIELDS + %w[preflight_hash]).each { |field| expect_sha(errors, record[field], field) }
    expect(errors, record["error_count"].is_a?(Integer) && record["error_count"] >= 0, "error_count must be a non-negative integer")
    validate_hash_binding(errors, record)
    validate_coupling(errors, record)
    errors
  end

  def validate_hash_binding(errors, record)
    return unless record["preflight_hash"].is_a?(String) && record["preflight_hash"].match?(SHA256_PATTERN)

    expect(errors, record["preflight_hash"] == preflight_hash(record), "preflight_hash mismatch")
  rescue ArgumentError => e
    errors << "preflight_hash cannot be recomputed: #{e.message}"
  end

  def validate_coupling(errors, record)
    attempted = record["attempted"]
    trusted = record["trusted"]
    decision = record["decision"]
    reason_code = record["reason_code"]
    return unless [attempted, trusted, record["would_block"]].all? { |value| value == true || value == false }

    expect(errors, attempted || !trusted, "trusted=true requires attempted=true")
    if record["would_block"]
      expect(errors, decision == "block", "would_block=true requires decision=block")
    end
    expect(errors, record["would_block"] == false, "decision=allow requires would_block=false") if decision == "allow"

    if attempted == false
      validate_not_attempted(errors, record)
    elsif trusted == false
      validate_untrusted(errors, record)
    else
      validate_trusted(errors, record)
    end
    validate_reason_decision_coupling(errors, record)
  end

  def validate_not_attempted(errors, record)
    expect(errors, record["trusted"] == false, "not-attempted preflight must be untrusted")
    expect(errors, record["decision"] == "unknown", "not-attempted preflight decision must be unknown")
    expect(errors, record["would_block"] == false, "not-attempted preflight would_block must be false")
    expect(errors, record["reason_code"] == "not-applicable", "not-attempted preflight reason_code must be not-applicable")
    expect(errors, record["tool_kind"] == "unknown", "not-attempted preflight tool_kind must be unknown")
    expect(errors, record["tool_write_intent"] == "unknown", "not-attempted preflight tool_write_intent must be unknown")
    expect(errors, record["error_count"] == 0, "not-attempted preflight error_count must be 0")
    DATA_HASH_FIELDS.each { |field| expect(errors, record[field] == ZERO_HASH, "not-attempted preflight #{field} must be zero hash") }
  end

  def validate_untrusted(errors, record)
    expect(errors, record["decision"] == "unknown", "untrusted preflight decision must be unknown")
    expect(errors, record["would_block"] == false, "untrusted preflight would_block must be false")
    expect_in(errors, record["reason_code"], UNTRUSTED_REASON_CODES, "untrusted reason_code")
    expect(errors, record["reason_hash"] == ZERO_HASH, "untrusted preflight reason_hash must be zero hash")
    expect(errors, record["tool_kind"] == "unknown", "untrusted preflight tool_kind must be unknown")
    expect(errors, record["tool_write_intent"] == "unknown", "untrusted preflight tool_write_intent must be unknown")
    %w[tool_name_hash command_hash path_list_hash].each { |field| expect(errors, record[field] == ZERO_HASH, "untrusted preflight #{field} must be zero hash") }
    expect(errors, record["error_count"].is_a?(Integer) && record["error_count"].positive?, "untrusted preflight error_count must be positive")
    expect(errors, record["error_hash"] != ZERO_HASH, "untrusted preflight error_hash must be nonzero")
  end

  def validate_trusted(errors, record)
    expect_in(errors, record["decision"], %w[allow block], "trusted decision")
    expect(errors, record["would_block"] == (record["decision"] == "block"), "trusted preflight would_block must match decision")
    expect_in(errors, record["reason_code"], CLASSIFIER_REASON_CODES, "trusted reason_code")
    expect(errors, record["reason_hash"] != ZERO_HASH, "trusted preflight reason_hash must be nonzero")
    expect(errors, record["error_count"] == 0, "trusted preflight error_count must be 0")
    expect(errors, record["error_hash"] == ZERO_HASH, "trusted preflight error_hash must be zero hash")
  end

  def validate_reason_decision_coupling(errors, record)
    reason_code = record["reason_code"]
    decision = record["decision"]
    return unless record["trusted"] == true

    expect(errors, decision == "allow", "allow classifier reason_code requires decision=allow") if CLASSIFIER_ALLOW_REASON_CODES.include?(reason_code)
    expect(errors, decision == "block", "block classifier reason_code requires decision=block") if CLASSIFIER_BLOCK_REASON_CODES.include?(reason_code)
  end

  def expect_sha(errors, value, field)
    expect(errors, value.is_a?(String) && value.match?(SHA256_PATTERN), "#{field} must be lowercase SHA-256")
  end

  def expect_bool(errors, value, field)
    expect(errors, value == true || value == false, "#{field} must be boolean")
  end

  def expect_in(errors, value, allowed, field)
    expect(errors, allowed.include?(value), "#{field} must be one of #{allowed.join(", ")}")
  end

  def expect(errors, condition, message)
    errors << message unless condition
  end
end
