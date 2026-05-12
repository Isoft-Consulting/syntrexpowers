# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "global_ledger_lib"
require_relative "global_lock_lib"
require_relative "metadata_lib"

class StrictModeFdrCycle
  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  MAX_CYCLES = 2
  ASSISTANT_TEXT_CAP_BYTES = 32_768
  TRUNCATION_MARKER = "[strict-mode-truncated-assistant-text]"
  PROMPT_TEMPLATE_HASH = ZERO_HASH

  CYCLE_FIELDS = %w[
    schema_version
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    turn_marker
    cycle_index
    max_cycles
    scope_digest
    tool_intent_seq_list
    tool_seq_list
    edit_seq_list
    tool_intent_log_digest
    tool_log_digest
    edit_log_digest
    content_scope_fingerprint_digest
    artifact_state
    artifact_hash
    artifact_verdict
    finding_count
    challenge_reason
    judge_backend
    judge_model
    prompt_hash
    response_hash
    decision
    original_challenge_record_hash
    bypass_marker_hash
    bypass_consumed_record_hash
    bypass_ledger_record_hash
    ts
    previous_record_hash
    record_hash
  ].freeze

  LEDGER_FIELDS = StrictModeGlobalLedger::LEDGER_FIELDS
  DECISIONS = %w[
    skipped-no-turn-text
    skipped-trivial
    judge-unknown
    judge-clean
    judge-challenge
    blocked-reused
    bypassed
  ].freeze
  UNKNOWN_REASONS = %w[
    judge-disabled
    judge-invocation-unverified
    judge-state-isolation-failed-until-repair
    timeout
    nonzero-exit
    invalid-output
    empty-output
    parse-failure
  ].freeze
  DECISION_REASONS = {
    "skipped-no-turn-text" => %w[no-normalized-turn-text],
    "skipped-trivial" => %w[trivial-diff],
    "judge-clean" => %w[judge-clean],
    "judge-challenge" => %w[judge-reported-challenge],
    "blocked-reused" => %w[reused-blocking-challenge],
    "bypassed" => %w[approved-quality-bypass],
    "judge-unknown" => UNKNOWN_REASONS
  }.freeze
  ARTIFACT_STATES = %w[missing invalid clean findings incomplete].freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def self.raw_session_id(payload)
    return "" unless payload.is_a?(Hash)

    %w[session_id conversation_id thread_id transcript_path chat_id].each do |key|
      value = payload[key]
      return value if value.is_a?(String) && !value.empty?
    end
    ""
  end

  def self.session_identity(provider, payload)
    raw = raw_session_id(payload)
    return nil if raw.empty?

    raw_hash = Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({ "provider" => provider, "raw_session_id" => raw }))
    prefix = raw.gsub(/[^A-Za-z0-9_-]/, "_")[0, 48]
    prefix = "session" if prefix.empty?
    {
      "session_key" => "#{prefix}-#{raw_hash}",
      "raw_session_hash" => raw_hash,
      "raw_session_id" => raw
    }
  end

  def self.cycle_path(state_root, provider, session_key)
    Pathname.new(state_root).join("fdr-cycles-#{provider}-#{session_key}.jsonl")
  end

  def self.ledger_path(state_root, provider, session_key)
    Pathname.new(state_root).join("trusted-state-ledger-#{provider}-#{session_key}.jsonl")
  end

  def self.lock_path(state_root, provider, session_key)
    Pathname.new(state_root).join("state-#{provider}-#{session_key}.lock")
  end

  def self.context(provider:, payload:, cwd:, project_dir:)
    identity = session_identity(provider, payload)
    return nil unless identity

    bounded = bounded_assistant_text(first_payload_string(payload, "last_assistant_message", "current_response", "assistant_text", "turn_assistant_text"))
    assistant_sha = bounded.fetch("text").empty? ? ZERO_HASH : Digest::SHA256.hexdigest(bounded.fetch("text"))
    tool_intent_seq_list = seq_list(payload, "tool_intent_seq_list")
    tool_seq_list = seq_list(payload, "tool_seq_list")
    edit_seq_list = seq_list(payload, "edit_seq_list")
    tool_intent_log_digest = digest_field(payload, "tool_intent_log_digest")
    tool_log_digest = digest_field(payload, "tool_log_digest")
    edit_log_digest = digest_field(payload, "edit_log_digest")
    content_scope_fingerprint_digest = digest_field(payload, "content_scope_fingerprint_digest")
    if content_scope_fingerprint_digest == ZERO_HASH
      content_scope_fingerprint_digest = Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
        "assistant_text_sha256" => assistant_sha,
        "assistant_text_bytes" => bounded.fetch("bytes"),
        "assistant_text_truncated" => bounded.fetch("truncated")
      }))
    end

    artifact = artifact_context(payload)
    scope_digest = Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "cwd" => cwd.to_s,
      "project_dir" => project_dir.to_s,
      "tool_intent_seq_list" => tool_intent_seq_list,
      "tool_seq_list" => tool_seq_list,
      "edit_seq_list" => edit_seq_list,
      "tool_intent_log_digest" => tool_intent_log_digest,
      "tool_log_digest" => tool_log_digest,
      "edit_log_digest" => edit_log_digest,
      "edited_paths" => string_list(payload, "edited_paths"),
      "deleted_paths" => string_list(payload, "deleted_paths"),
      "renamed_paths" => string_list(payload, "renamed_paths"),
      "content_scope_fingerprint_digest" => content_scope_fingerprint_digest
    }))

    identity.merge(
      "provider" => provider,
      "cwd" => cwd.to_s,
      "project_dir" => project_dir.to_s,
      "turn_marker" => turn_marker(provider, identity.fetch("raw_session_hash"), cwd, project_dir, assistant_sha, payload),
      "assistant_text" => bounded.fetch("text"),
      "assistant_text_sha256" => assistant_sha,
      "assistant_text_bytes" => bounded.fetch("bytes"),
      "assistant_text_truncated" => bounded.fetch("truncated"),
      "scope_digest" => scope_digest,
      "tool_intent_seq_list" => tool_intent_seq_list,
      "tool_seq_list" => tool_seq_list,
      "edit_seq_list" => edit_seq_list,
      "tool_intent_log_digest" => tool_intent_log_digest,
      "tool_log_digest" => tool_log_digest,
      "edit_log_digest" => edit_log_digest,
      "content_scope_fingerprint_digest" => content_scope_fingerprint_digest
    ).merge(artifact)
  end

  def self.reusable_result(state_root, context, prompt_template_hash: PROMPT_TEMPLATE_HASH)
    records = load_cycle_records(cycle_path(state_root, context.fetch("provider"), context.fetch("session_key")))
    matching = records.select do |record|
      record.fetch("scope_digest") == context.fetch("scope_digest") &&
        record.fetch("artifact_hash") == context.fetch("artifact_hash") &&
        prompt_hash_matches?(record, context, prompt_template_hash)
    end
    clean = matching.reverse.find { |record| record.fetch("decision") == "judge-clean" }
    return { "decision" => "judge-clean", "record" => clean } if clean

    challenge = matching.reverse.find { |record| record.fetch("decision") == "judge-challenge" }
    return { "decision" => "judge-challenge", "record" => challenge } if challenge

    scope_challenges = records.select do |record|
      record.fetch("decision") == "judge-challenge" &&
        record.fetch("scope_digest") == context.fetch("scope_digest") &&
        prompt_hash_matches?(record, context, prompt_template_hash)
    end
    distinct_artifacts = scope_challenges.map { |record| record.fetch("artifact_hash") }.uniq
    return { "decision" => "judge-challenge", "record" => scope_challenges.last } if distinct_artifacts.length >= MAX_CYCLES

    nil
  rescue JSON::ParserError, RuntimeError
    nil
  end

  def self.prompt_hash_matches?(record, context, prompt_template_hash)
    return true unless %w[judge-clean judge-challenge].include?(record.fetch("decision"))

    record_context = context.merge(
      "artifact_state" => record.fetch("artifact_state"),
      "artifact_hash" => record.fetch("artifact_hash"),
      "artifact_verdict" => record.fetch("artifact_verdict"),
      "finding_count" => record.fetch("finding_count")
    )
    expected = prompt_hash(
      record_context,
      judge_backend: record.fetch("judge_backend"),
      judge_model: record.fetch("judge_model"),
      prompt_template_hash: prompt_template_hash
    )
    record.fetch("prompt_hash") == expected
  end

  def self.append_cycle!(state_root, context, decision:, challenge_reason:, judge_backend: "", judge_model: "", prompt_hash: ZERO_HASH, response_hash: ZERO_HASH, original_challenge_record_hash: ZERO_HASH)
    path = cycle_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    with_session_lock!(state_root, context, "fdr-cycle") do
      old_fingerprint = StrictModeGlobalLedger.fingerprint(path)
      previous_record_hash = last_cycle_record_hash(path)
      cycle_index = cycle_index_for(path, context, decision, original_challenge_record_hash)
      record = {
        "schema_version" => 1,
        "provider" => context.fetch("provider"),
        "session_key" => context.fetch("session_key"),
        "raw_session_hash" => context.fetch("raw_session_hash"),
        "cwd" => context.fetch("cwd"),
        "project_dir" => context.fetch("project_dir"),
        "turn_marker" => context.fetch("turn_marker"),
        "cycle_index" => cycle_index,
        "max_cycles" => MAX_CYCLES,
        "scope_digest" => context.fetch("scope_digest"),
        "tool_intent_seq_list" => context.fetch("tool_intent_seq_list"),
        "tool_seq_list" => context.fetch("tool_seq_list"),
        "edit_seq_list" => context.fetch("edit_seq_list"),
        "tool_intent_log_digest" => context.fetch("tool_intent_log_digest"),
        "tool_log_digest" => context.fetch("tool_log_digest"),
        "edit_log_digest" => context.fetch("edit_log_digest"),
        "content_scope_fingerprint_digest" => context.fetch("content_scope_fingerprint_digest"),
        "artifact_state" => context.fetch("artifact_state"),
        "artifact_hash" => context.fetch("artifact_hash"),
        "artifact_verdict" => context.fetch("artifact_verdict"),
        "finding_count" => context.fetch("finding_count"),
        "challenge_reason" => challenge_reason,
        "judge_backend" => judge_backend,
        "judge_model" => judge_model,
        "prompt_hash" => prompt_hash,
        "response_hash" => response_hash,
        "decision" => decision,
        "original_challenge_record_hash" => original_challenge_record_hash,
        "bypass_marker_hash" => ZERO_HASH,
        "bypass_consumed_record_hash" => ZERO_HASH,
        "bypass_ledger_record_hash" => ZERO_HASH,
        "ts" => Time.now.utc.iso8601,
        "previous_record_hash" => previous_record_hash,
        "record_hash" => ""
      }
      record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
      errors = validate_cycle_record(record, expected_previous_hash: previous_record_hash)
      raise "FDR cycle record invalid: #{errors.join("; ")}" unless errors.empty?

      path.dirname.mkpath
      new_file = !path.exist?
      old_size = path.file? && !path.symlink? ? path.size : 0
      File.open(path.to_s, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.write(JSON.generate(record) + "\n") }
      File.chmod(0o600, path) if new_file
      new_fingerprint = StrictModeGlobalLedger.fingerprint(path)
      begin
        ledger_record = append_session_ledger!(
          state_root,
          context,
          target_path: path,
          target_class: "fdr-cycle-log",
          operation: "append",
          old_fingerprint: old_fingerprint,
          new_fingerprint: new_fingerprint,
          related_record_hash: record.fetch("record_hash")
        )
      rescue RuntimeError, SystemCallError
        rollback_cycle_append(path, old_size, new_file)
        raise
      end
      record.merge("ledger_record_hash" => ledger_record.fetch("record_hash"))
    end
  end

  def self.prompt_hash(context, judge_backend:, judge_model:, prompt_template_hash: PROMPT_TEMPLATE_HASH)
    return ZERO_HASH if context.fetch("assistant_text_sha256") == ZERO_HASH
    raise ArgumentError, "prompt_template_hash must be lowercase SHA-256" unless sha256?(prompt_template_hash)

    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "scope_digest" => context.fetch("scope_digest"),
      "artifact_state" => context.fetch("artifact_state"),
      "artifact_hash" => context.fetch("artifact_hash"),
      "artifact_verdict" => context.fetch("artifact_verdict"),
      "finding_count" => context.fetch("finding_count"),
      "judge_backend" => judge_backend,
      "judge_model" => judge_model,
      "prompt_template_hash" => prompt_template_hash,
      "assistant_text_sha256" => context.fetch("assistant_text_sha256"),
      "assistant_text_bytes" => context.fetch("assistant_text_bytes"),
      "assistant_text_truncated" => context.fetch("assistant_text_truncated")
    }))
  end

  def self.failure_response_hash(context, reason_code:, timed_out:, exit_status:, stdout:, stderr:, judge_backend: "", judge_model: "")
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "scope_digest" => context.fetch("scope_digest"),
      "artifact_hash" => context.fetch("artifact_hash"),
      "judge_backend" => judge_backend,
      "judge_model" => judge_model,
      "reason_code" => reason_code,
      "timed_out" => timed_out ? 1 : 0,
      "exit_status" => exit_status || -1,
      "stdout_sha256" => Digest::SHA256.hexdigest(stdout.to_s),
      "stderr_sha256" => Digest::SHA256.hexdigest(stderr.to_s),
      "stdout_bytes_captured" => stdout.to_s.bytesize,
      "stderr_bytes_captured" => stderr.to_s.bytesize,
      "stdout_truncated" => 0,
      "stderr_truncated" => 0
    }))
  end

  def self.load_cycle_records(path)
    path = Pathname.new(path)
    return [] unless path.exist?
    raise "#{path}: FDR cycle log must be a file" unless path.file?
    raise "#{path}: FDR cycle log must not be a symlink" if path.symlink?

    records = path.read.lines.each_with_index.map do |line, index|
      text = line.strip
      raise "#{path}: blank FDR cycle line #{index + 1}" if text.empty?

      record = JSON.parse(text, object_class: DuplicateKeyHash)
      raise "#{path}: FDR cycle line #{index + 1} must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
    validate_cycle_chain_records!(path, records)
    records
  end

  def self.load_session_ledger_records(path)
    path = Pathname.new(path)
    return [] unless path.exist?
    raise "#{path}: session ledger must be a file" unless path.file?
    raise "#{path}: session ledger must not be a symlink" if path.symlink?

    records = path.read.lines.each_with_index.map do |line, index|
      text = line.strip
      raise "#{path}: blank session ledger line #{index + 1}" if text.empty?

      record = JSON.parse(text, object_class: DuplicateKeyHash)
      raise "#{path}: session ledger line #{index + 1} must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
    validate_session_ledger_chain_records!(path, records)
    records
  end

  def self.validate_cycle_record(record, expected_previous_hash: nil)
    return ["FDR cycle record must be a JSON object"] unless record.is_a?(Hash)

    errors = []
    errors.concat(field_errors(record, CYCLE_FIELDS, "FDR cycle"))
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "provider invalid" unless %w[claude codex].include?(record.fetch("provider"))
    %w[session_key raw_session_hash cwd project_dir turn_marker challenge_reason judge_backend judge_model decision].each do |field|
      errors << "#{field} must be a string" unless record.fetch(field).is_a?(String)
    end
    %w[cycle_index max_cycles finding_count].each do |field|
      errors << "#{field} must be a non-negative integer" unless record.fetch(field).is_a?(Integer) && record.fetch(field) >= 0
    end
    %w[raw_session_hash scope_digest tool_intent_log_digest tool_log_digest edit_log_digest content_scope_fingerprint_digest artifact_hash prompt_hash response_hash original_challenge_record_hash bypass_marker_hash bypass_consumed_record_hash bypass_ledger_record_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "previous_record_hash mismatch" if expected_previous_hash && record.fetch("previous_record_hash") != expected_previous_hash
    errors << "record_hash mismatch" if sha256?(record.fetch("record_hash")) &&
      StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
    %w[tool_intent_seq_list tool_seq_list edit_seq_list].each do |field|
      errors << "#{field} must be an array of non-negative integers" unless seq_list_value?(record.fetch(field))
    end
    errors << "max_cycles must be #{MAX_CYCLES}" unless record.fetch("max_cycles") == MAX_CYCLES
    errors << "decision invalid" unless DECISIONS.include?(record.fetch("decision"))
    if DECISIONS.include?(record.fetch("decision")) && !DECISION_REASONS.fetch(record.fetch("decision")).include?(record.fetch("challenge_reason"))
      errors << "challenge_reason invalid for decision"
    end
    errors.concat(validate_artifact_coupling(record))
    errors.concat(validate_hash_sentinels(record))
    errors
  end

  def self.validate_session_ledger_record(record, expected_previous_hash: nil)
    return ["session ledger record must be a JSON object"] unless record.is_a?(Hash)

    errors = []
    errors.concat(field_errors(record, LEDGER_FIELDS, "session ledger"))
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "ledger_scope must be session" unless record.fetch("ledger_scope") == "session"
    errors << "writer must be strict-hook" unless record.fetch("writer") == "strict-hook"
    errors << "provider invalid" unless %w[claude codex].include?(record.fetch("provider"))
    %w[session_key raw_session_hash cwd project_dir target_path target_class operation].each do |field|
      errors << "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty?
    end
    errors << "target_class invalid" unless record.fetch("target_class") == "fdr-cycle-log"
    errors << "operation must be append" unless record.fetch("operation") == "append"
    %w[raw_session_hash related_record_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "previous_record_hash mismatch" if expected_previous_hash && record.fetch("previous_record_hash") != expected_previous_hash
    errors << "record_hash mismatch" if sha256?(record.fetch("record_hash")) &&
      StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
    %w[old_fingerprint new_fingerprint].each do |field|
      errors.concat(StrictModeGlobalLedger.validate_fingerprint(record.fetch(field)).map { |error| "#{field}: #{error}" })
    end
    errors
  end

  def self.validate_cycle_chain(path)
    validate_cycle_chain_records!(path, load_cycle_records_without_chain(path))
    []
  rescue JSON::ParserError, RuntimeError => e
    [e.message]
  end

  def self.validate_session_ledger_chain(path)
    validate_session_ledger_chain_records!(path, load_session_ledger_records_without_chain(path))
    []
  rescue JSON::ParserError, RuntimeError => e
    [e.message]
  end

  def self.last_cycle_record_hash(path)
    records = load_cycle_records(path)
    records.empty? ? ZERO_HASH : records.last.fetch("record_hash")
  end

  def self.last_session_ledger_hash(path)
    records = load_session_ledger_records(path)
    records.empty? ? ZERO_HASH : records.last.fetch("record_hash")
  end

  def self.first_payload_string(payload, *keys)
    return "" unless payload.is_a?(Hash)

    keys.each do |key|
      value = payload[key]
      return value if value.is_a?(String) && !value.empty?
    end
    ""
  end

  def self.bounded_assistant_text(text)
    value = text.to_s
    return { "text" => value, "bytes" => value.bytesize, "truncated" => 0 } if value.bytesize <= ASSISTANT_TEXT_CAP_BYTES

    head_limit = (ASSISTANT_TEXT_CAP_BYTES - TRUNCATION_MARKER.bytesize) / 2
    tail_limit = ASSISTANT_TEXT_CAP_BYTES - TRUNCATION_MARKER.bytesize - head_limit
    bounded = prefix_bytes(value, head_limit) + TRUNCATION_MARKER + suffix_bytes(value, tail_limit)
    { "text" => bounded, "bytes" => bounded.bytesize, "truncated" => 1 }
  end

  def self.prefix_bytes(text, limit)
    out = +""
    text.each_char do |char|
      break if out.bytesize + char.bytesize > limit

      out << char
    end
    out
  end

  def self.suffix_bytes(text, limit)
    out = +""
    text.each_char.to_a.reverse_each do |char|
      break if out.bytesize + char.bytesize > limit

      out.prepend(char)
    end
    out
  end

  def self.seq_list(payload, key)
    value = payload.is_a?(Hash) ? payload[key] : nil
    return [] unless value.is_a?(Array)

    value.select { |item| item.is_a?(Integer) && item >= 0 }
  end

  def self.string_list(payload, key)
    value = payload.is_a?(Hash) ? payload[key] : nil
    return [] unless value.is_a?(Array)

    value.select { |item| item.is_a?(String) }.sort
  end

  def self.digest_field(payload, key)
    value = payload.is_a?(Hash) ? payload[key] : nil
    sha256?(value) ? value : ZERO_HASH
  end

  def self.artifact_context(payload)
    source = payload.is_a?(Hash) && payload["fdr_artifact"].is_a?(Hash) ? payload["fdr_artifact"] : payload
    state = source.is_a?(Hash) && ARTIFACT_STATES.include?(source["artifact_state"]) ? source["artifact_state"] : "missing"
    if state == "missing"
      return {
        "artifact_state" => "missing",
        "artifact_hash" => ZERO_HASH,
        "artifact_verdict" => "",
        "finding_count" => 0
      }
    end

    verdict = %w[clean findings incomplete].include?(state) ? state : ""
    {
      "artifact_state" => state,
      "artifact_hash" => sha256?(source["artifact_hash"]) ? source["artifact_hash"] : ZERO_HASH,
      "artifact_verdict" => source["artifact_verdict"] == verdict ? verdict : verdict,
      "finding_count" => source["finding_count"].is_a?(Integer) && source["finding_count"] >= 0 ? source["finding_count"] : 0
    }
  end

  def self.turn_marker(provider, raw_session_hash, cwd, project_dir, assistant_sha, payload)
    explicit = payload.is_a?(Hash) ? payload["turn_marker"] : nil
    return explicit if explicit.is_a?(String) && !explicit.empty?

    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "provider" => provider,
      "raw_session_hash" => raw_session_hash,
      "cwd" => cwd.to_s,
      "project_dir" => project_dir.to_s,
      "assistant_text_sha256" => assistant_sha
    }))
  end

  def self.cycle_index_for(path, context, decision, original_challenge_record_hash)
    return 0 if %w[skipped-no-turn-text skipped-trivial judge-unknown judge-clean].include?(decision)
    if decision == "blocked-reused"
      original = load_cycle_records(path).find { |record| record.fetch("record_hash") == original_challenge_record_hash }
      return original.fetch("cycle_index") if original
    end
    if decision == "judge-challenge"
      hashes = load_cycle_records(path).select do |record|
        record.fetch("decision") == "judge-challenge" &&
          record.fetch("scope_digest") == context.fetch("scope_digest")
      end.map { |record| record.fetch("artifact_hash") }.uniq
      return hashes.include?(context.fetch("artifact_hash")) ? hashes.index(context.fetch("artifact_hash")) + 1 : hashes.length + 1
    end
    0
  end

  def self.append_session_ledger!(state_root, context, target_path:, target_class:, operation:, old_fingerprint:, new_fingerprint:, related_record_hash:)
    path = ledger_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    path.dirname.mkpath
    previous_record_hash = last_session_ledger_hash(path)
    record = {
      "schema_version" => 1,
      "ledger_scope" => "session",
      "writer" => "strict-hook",
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "target_path" => Pathname.new(target_path).to_s,
      "target_class" => target_class,
      "operation" => operation,
      "old_fingerprint" => old_fingerprint,
      "new_fingerprint" => new_fingerprint,
      "related_record_hash" => related_record_hash,
      "ts" => Time.now.utc.iso8601,
      "previous_record_hash" => previous_record_hash,
      "record_hash" => ""
    }
    record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
    errors = validate_session_ledger_record(record, expected_previous_hash: previous_record_hash)
    raise "session ledger record invalid: #{errors.join("; ")}" unless errors.empty?

    new_file = !path.exist?
    File.open(path.to_s, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.write(JSON.generate(record) + "\n") }
    File.chmod(0o600, path) if new_file
    record
  end

  def self.with_session_lock!(state_root, context, transaction_kind)
    path = lock_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    acquired = false
    path.dirname.mkpath
    begin
      Dir.mkdir(path.to_s, 0o700)
      acquired = true
    rescue Errno::EEXIST
      raise "#{path}: another session transaction is active"
    end
    write_session_owner!(path, context, transaction_kind)
    yield
  ensure
    release_session_lock(path) if path && acquired
  end

  def self.write_session_owner!(path, context, transaction_kind)
    created = Time.now.utc
    owner = {
      "schema_version" => 1,
      "lock_scope" => "session",
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "transaction_kind" => transaction_kind,
      "pid" => Process.pid,
      "process_start" => "",
      "created_at" => created.iso8601,
      "timeout_at" => (created + 3600).iso8601,
      "owner_hash" => ""
    }
    owner["owner_hash"] = StrictModeMetadata.hash_record(owner, "owner_hash")
    errors = StrictModeGlobalLock.validate_owner(owner, expected_scope: "session")
    raise "session lock owner invalid: #{errors.join("; ")}" unless errors.empty?

    tmp = path.join(".owner.json.tmp-#{$$}-#{SecureRandom.hex(4)}")
    tmp.write(JSON.pretty_generate(owner) + "\n")
    File.chmod(0o600, tmp)
    File.rename(tmp, path.join("owner.json"))
  end

  def self.release_session_lock(path)
    owner_path = path.join("owner.json")
    FileUtils.rm_f(owner_path) if owner_path.file? && !owner_path.symlink?
    Dir.rmdir(path.to_s) if File.directory?(path.to_s)
  rescue Errno::ENOENT
    nil
  end

  def self.rollback_cycle_append(path, old_size, new_file)
    if new_file
      FileUtils.rm_f(path) if path.file? && !path.symlink?
    elsif path.file? && !path.symlink?
      File.open(path.to_s, "r+b") { |file| file.truncate(old_size) }
    end
  rescue SystemCallError
    nil
  end

  def self.validate_cycle_chain_records!(path, records)
    previous = ZERO_HASH
    records.each_with_index do |record, index|
      errors = validate_cycle_record(record, expected_previous_hash: previous)
      raise "#{path}: invalid FDR cycle line #{index + 1}: #{errors.join("; ")}" unless errors.empty?

      previous = record.fetch("record_hash")
    end
  end

  def self.validate_session_ledger_chain_records!(path, records)
    previous = ZERO_HASH
    records.each_with_index do |record, index|
      errors = validate_session_ledger_record(record, expected_previous_hash: previous)
      raise "#{path}: invalid session ledger line #{index + 1}: #{errors.join("; ")}" unless errors.empty?

      previous = record.fetch("record_hash")
    end
  end

  def self.load_cycle_records_without_chain(path)
    path = Pathname.new(path)
    return [] unless path.exist?

    path.read.lines.map { |line| JSON.parse(line, object_class: DuplicateKeyHash) }
  end

  def self.load_session_ledger_records_without_chain(path)
    path = Pathname.new(path)
    return [] unless path.exist?

    path.read.lines.map { |line| JSON.parse(line, object_class: DuplicateKeyHash) }
  end

  def self.validate_artifact_coupling(record)
    state = record.fetch("artifact_state")
    return ["artifact_state invalid"] unless ARTIFACT_STATES.include?(state)

    case state
    when "missing"
      errors = []
      errors << "missing artifact_hash must be zero" unless record.fetch("artifact_hash") == ZERO_HASH
      errors << "missing artifact_verdict must be empty" unless record.fetch("artifact_verdict") == ""
      errors << "missing finding_count must be 0" unless record.fetch("finding_count") == 0
      errors
    when "invalid"
      ["invalid artifact_hash must be nonzero"].reject { record.fetch("artifact_hash") != ZERO_HASH } +
        ["invalid artifact_verdict must be empty"].reject { record.fetch("artifact_verdict") == "" } +
        ["invalid finding_count must be 0"].reject { record.fetch("finding_count") == 0 }
    else
      errors = []
      errors << "artifact_hash must be nonzero" if record.fetch("artifact_hash") == ZERO_HASH
      errors << "artifact_verdict must equal artifact_state" unless record.fetch("artifact_verdict") == state
      errors
    end
  end

  def self.validate_hash_sentinels(record)
    decision = record.fetch("decision")
    errors = []
    bypass_hashes = %w[bypass_marker_hash bypass_consumed_record_hash bypass_ledger_record_hash]
    case decision
    when "judge-challenge"
      errors << "judge-challenge prompt_hash must be nonzero" if record.fetch("prompt_hash") == ZERO_HASH
      errors << "judge-challenge response_hash must be nonzero" if record.fetch("response_hash") == ZERO_HASH
      errors << "judge-challenge original hash must be zero" unless record.fetch("original_challenge_record_hash") == ZERO_HASH
    when "judge-clean"
      errors << "judge-clean prompt_hash must be nonzero" if record.fetch("prompt_hash") == ZERO_HASH
      errors << "judge-clean response_hash must be nonzero" if record.fetch("response_hash") == ZERO_HASH
      errors << "judge-clean original hash must be zero" unless record.fetch("original_challenge_record_hash") == ZERO_HASH
    when "blocked-reused"
      errors << "blocked-reused original hash must be nonzero" if record.fetch("original_challenge_record_hash") == ZERO_HASH
      errors << "blocked-reused prompt_hash must be zero" unless record.fetch("prompt_hash") == ZERO_HASH
      errors << "blocked-reused response_hash must be zero" unless record.fetch("response_hash") == ZERO_HASH
    when "bypassed"
      errors << "bypassed original hash must be nonzero" if record.fetch("original_challenge_record_hash") == ZERO_HASH
      bypass_hashes.each { |field| errors << "#{field} must be nonzero for bypassed" if record.fetch(field) == ZERO_HASH }
    else
      errors << "#{decision} prompt_hash must be zero" unless record.fetch("prompt_hash") == ZERO_HASH if decision.start_with?("skipped")
      errors << "#{decision} response_hash must be zero" unless record.fetch("response_hash") == ZERO_HASH if decision.start_with?("skipped")
      errors << "#{decision} original hash must be zero" unless record.fetch("original_challenge_record_hash") == ZERO_HASH
    end
    bypass_hashes.each { |field| errors << "#{decision} #{field} must be zero" unless record.fetch(field) == ZERO_HASH } unless decision == "bypassed"
    errors
  end

  def self.field_errors(record, expected_fields, label)
    actual = record.keys.sort
    expected = expected_fields.sort
    return [] if actual == expected

    missing = expected - actual
    extra = actual - expected
    details = []
    details << "missing #{missing.join(", ")}" unless missing.empty?
    details << "extra #{extra.join(", ")}" unless extra.empty?
    ["#{label} fields mismatch (#{details.join("; ")})"]
  end

  def self.seq_list_value?(value)
    value.is_a?(Array) && value.all? { |item| item.is_a?(Integer) && item >= 0 }
  end

  def self.sha256?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end
end
