#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "fixture_manifest_lib"

module StrictModeProviderDetection
  extend self

  ZERO_HASH = "0" * 64
  PROVIDERS = %w[claude codex unknown].freeze
  DETECTED_PROVIDERS = %w[claude codex unknown conflict].freeze
  DECISIONS = %w[match mismatch unknown conflict].freeze
  PROVIDER_ARG_SOURCES = %w[argv env payload manual fixture-import unknown].freeze
  PROOF_FIELDS = %w[
    schema_version
    provider_arg
    provider_arg_source
    payload_sha256
    detected_provider
    decision
    claude_indicators
    codex_indicators
    conflict_indicators
    fixture_usable
    enforcement_usable
    diagnostic
    provider_proof_hash
  ].freeze
  SHA256_PATTERN = /\A[a-f0-9]{64}\z/
  CLAUDE_NATIVE_EVENTS = %w[SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SubagentStop].freeze
  CLAUDE_TOOL_NAMES = %w[Bash Write Edit MultiEdit Read Glob Grep LS Task WebFetch WebSearch].freeze
  CODEX_LOGICAL_EVENTS = %w[session-start user-prompt-submit pre-tool-use post-tool-use stop permission-request].freeze
  CODEX_TOOL_NAMES = %w[apply_patch exec_command].freeze

  def load_payload(path)
    payload = Pathname.new(path).binread
    parsed = JSON.parse(payload, object_class: StrictModeFixtures::DuplicateKeyHash)
    raise "#{path}: payload JSON root must be an object" unless parsed.is_a?(Hash)

    [payload, JSON.parse(JSON.generate(parsed))]
  rescue JSON::ParserError, SystemCallError, RuntimeError => e
    raise "#{path}: malformed payload JSON: #{e.message}"
  end

  def proof(payload, provider_arg:, provider_arg_source:, payload_sha256:)
    provider_arg = provider_arg.to_s
    provider_arg_source = provider_arg_source.to_s
    raise "provider_arg must be claude, codex, or unknown" unless PROVIDERS.include?(provider_arg)
    raise "provider_arg_source must be a closed source" unless PROVIDER_ARG_SOURCES.include?(provider_arg_source)
    raise "payload_sha256 must be lowercase SHA-256" unless sha?(payload_sha256)

    claude = claude_indicators(payload)
    codex = codex_indicators(payload)
    detected_provider = detected_provider_for(claude, codex)
    decision = decision_for(provider_arg, detected_provider)
    diagnostic = diagnostic_for(provider_arg, detected_provider, decision, claude, codex)
    record = {
      "schema_version" => 1,
      "provider_arg" => provider_arg,
      "provider_arg_source" => provider_arg_source,
      "payload_sha256" => payload_sha256,
      "detected_provider" => detected_provider,
      "decision" => decision,
      "claude_indicators" => claude,
      "codex_indicators" => codex,
      "conflict_indicators" => (detected_provider == "conflict" ? (claude + codex).uniq.sort : []),
      "fixture_usable" => decision == "match",
      "enforcement_usable" => false,
      "diagnostic" => diagnostic,
      "provider_proof_hash" => ""
    }
    record["provider_proof_hash"] = hash_record(record)
    record
  end

  def validate(record)
    errors = []
    unless record.is_a?(Hash)
      return ["provider proof must be an object"]
    end
    expect(errors, record.keys.sort == PROOF_FIELDS.sort, "provider proof fields must be exact")
    expect(errors, record["schema_version"] == 1, "schema_version must be 1")
    expect_in(errors, record["provider_arg"], PROVIDERS, "provider_arg")
    expect_in(errors, record["provider_arg_source"], PROVIDER_ARG_SOURCES, "provider_arg_source")
    expect_sha(errors, record["payload_sha256"], "payload_sha256")
    expect_in(errors, record["detected_provider"], DETECTED_PROVIDERS, "detected_provider")
    expect_in(errors, record["decision"], DECISIONS, "decision")
    expect_sorted_string_array(errors, record["claude_indicators"], "claude_indicators")
    expect_sorted_string_array(errors, record["codex_indicators"], "codex_indicators")
    expect_sorted_string_array(errors, record["conflict_indicators"], "conflict_indicators")
    expect(errors, record["fixture_usable"] == true || record["fixture_usable"] == false, "fixture_usable must be boolean")
    expect(errors, record["enforcement_usable"] == false, "enforcement_usable must be false in Phase 0")
    expect(errors, record["diagnostic"].is_a?(String), "diagnostic must be a string")
    expect_sha(errors, record["provider_proof_hash"], "provider_proof_hash")
    if record["decision"] == "match"
      expect(errors, record["detected_provider"] == record["provider_arg"], "match decision must bind detected_provider to provider_arg")
      expect(errors, record["fixture_usable"] == true, "match decision must be fixture_usable")
    else
      expect(errors, record["fixture_usable"] == false, "non-match decision must not be fixture_usable")
    end
    if record["detected_provider"] == "conflict"
      expect(errors, record["decision"] == "conflict", "conflict detected_provider requires conflict decision")
      expected = []
      expected.concat(record["claude_indicators"]) if record["claude_indicators"].is_a?(Array)
      expected.concat(record["codex_indicators"]) if record["codex_indicators"].is_a?(Array)
      expect(errors, record["conflict_indicators"] == expected.uniq.sort, "conflict_indicators must combine provider indicators")
    else
      expect(errors, record["conflict_indicators"] == [], "non-conflict proof must have empty conflict_indicators")
    end
    if record["provider_proof_hash"].is_a?(String)
      expect(errors, record["provider_proof_hash"] == hash_record(record), "provider_proof_hash mismatch")
    end
    errors
  end

  def hash_record(record)
    clone = JSON.parse(JSON.generate(record))
    clone["provider_proof_hash"] = ""
    StrictModeMetadata.hash_record(clone, "provider_proof_hash")
  end

  def claude_indicators(payload)
    indicators = []
    indicators << "key:hook_event_name" if payload.key?("hook_event_name") || payload.key?("hookEventName")
    indicators << "key:transcript_path" if payload.key?("transcript_path") || payload.key?("transcriptPath")
    indicators << "key:session_id" if payload.key?("session_id")
    event_name = string_value(payload, "hook_event_name", "hookEventName")
    indicators << "event:#{event_name}" if CLAUDE_NATIVE_EVENTS.include?(event_name)
    tool_name = string_value(payload, "tool_name", "toolName", "name") || string_value(hash_value(payload, "tool_input", "tool", "input") || {}, "name", "tool_name")
    indicators << "tool:#{tool_name}" if CLAUDE_TOOL_NAMES.include?(tool_name)
    indicators.uniq.sort
  end

  def codex_indicators(payload)
    indicators = []
    indicators << "key:thread_id" if payload.key?("thread_id")
    indicators << "key:conversation_id" if payload.key?("conversation_id")
    indicators << "key:turn_id" if payload.key?("turn_id")
    indicators << "key:approval_request_id" if payload.key?("approval_request_id") || payload.key?("request_id")
    event_name = string_value(payload, "event", "type", "hook_event_name")
    indicators << "event:#{event_name}" if CODEX_LOGICAL_EVENTS.include?(event_name)
    tool_name = string_value(payload, "tool_name", "toolName", "name") || string_value(hash_value(payload, "tool_input", "tool", "input") || {}, "name", "tool_name")
    indicators << "tool:#{tool_name}" if CODEX_TOOL_NAMES.include?(tool_name.to_s.downcase)
    indicators.uniq.sort
  end

  def detected_provider_for(claude_indicators, codex_indicators)
    return "conflict" unless claude_indicators.empty? || codex_indicators.empty?
    return "claude" unless claude_indicators.empty?
    return "codex" unless codex_indicators.empty?

    "unknown"
  end

  def decision_for(provider_arg, detected_provider)
    return "conflict" if detected_provider == "conflict"
    return "unknown" if detected_provider == "unknown"

    provider_arg == detected_provider ? "match" : "mismatch"
  end

  def diagnostic_for(provider_arg, detected_provider, decision, claude_indicators, codex_indicators)
    case decision
    when "match"
      "provider #{provider_arg} matched payload indicators"
    when "mismatch"
      "provider #{provider_arg} mismatches detected #{detected_provider}"
    when "conflict"
      "payload has conflicting provider indicators: claude=#{claude_indicators.join(",")} codex=#{codex_indicators.join(",")}"
    else
      "provider #{provider_arg} could not be proven from payload indicators"
    end
  end

  def hash_value(hash, *keys)
    keys.each do |key|
      value = hash[key]
      return value if value.is_a?(Hash)
    end
    nil
  end

  def string_value(hash, *keys)
    keys.each do |key|
      value = hash[key]
      return value if value.is_a?(String)
    end
    nil
  end

  def sha?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end

  def expect_sorted_string_array(errors, value, field)
    unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) } && value == value.uniq.sort
      errors << "#{field} must be a sorted unique string array"
    end
  end

  def expect_sha(errors, value, field)
    expect(errors, sha?(value), "#{field} must be lowercase SHA-256")
  end

  def expect_in(errors, value, allowed, field)
    expect(errors, allowed.include?(value), "#{field} must be one of #{allowed.join(", ")}")
  end

  def expect(errors, condition, message)
    errors << message unless condition
  end
end
