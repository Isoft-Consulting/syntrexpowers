# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"
require_relative "destructive_gate_lib"
require_relative "fdr_cycle_lib"
require_relative "global_ledger_lib"
require_relative "metadata_lib"
require_relative "normalized_event_lib"

module StrictModeRecordEdit
  extend self

  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  COMMAND_HASH_SOURCES = %w[none shell-string argv trusted-import-argv].freeze
  TOOL_INTENT_FIELDS = %w[
    schema_version
    seq
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    turn_marker
    logical_event
    tool_kind
    tool_name
    normalized_command_hash
    command_hash_source
    normalized_path_list
    payload_hash
    write_intent
    ts
    intent_hash
  ].freeze
  TOOL_FIELDS = %w[
    schema_version
    seq
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    turn_marker
    tool_kind
    tool_name
    command_hash
    command_hash_source
    write_intent
    payload_hash
    pre_tool_intent_seq
    pre_tool_intent_hash
    ts
    record_hash
  ].freeze
  EDIT_FIELDS = %w[
    schema_version
    seq
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    turn_marker
    path
    old_path
    new_path
    action
    source
    ts
    record_hash
  ].freeze
  EDIT_ACTIONS = %w[create modify delete rename].freeze
  EDIT_SOURCES = %w[payload patch dirty-snapshot].freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def append_pre_tool_intent_from_payload!(state_root:, provider:, payload:, payload_hash:, cwd:, project_dir:)
    return nil unless payload.is_a?(Hash)

    event = normalize(payload, provider: provider, logical_event: "pre-tool-use", cwd: cwd, project_dir: project_dir, payload_hash: payload_hash)
    tool = event.fetch("tool")
    return nil unless intent_required?(tool)

    context = session_context(provider: provider, payload: payload, cwd: cwd, project_dir: project_dir)
    raise "tool intent requires stable provider session id" unless context

    append_tool_intent!(state_root, context, event)
  end

  def append_post_tool_records_from_payload!(state_root:, provider:, payload:, payload_hash:, cwd:, project_dir:)
    raise "post-tool record requires payload object" unless payload.is_a?(Hash)

    event = normalize(payload, provider: provider, logical_event: "post-tool-use", cwd: cwd, project_dir: project_dir, payload_hash: payload_hash)
    context = session_context(provider: provider, payload: payload, cwd: cwd, project_dir: project_dir)
    raise "post-tool record requires stable provider session id" unless context

    state_root = Pathname.new(state_root)
    StrictModeFdrCycle.with_session_lock!(state_root, context, "post-tool-record") do
      intent = find_matching_intent(state_root, context, event)
      tool_record = append_tool_record!(state_root, context, event, intent)
      edit_records = event.fetch("tool").fetch("file_changes").map do |change|
        append_edit_record!(state_root, context, event, change)
      end
      {
        "recorded" => true,
        "tool_record_hash" => tool_record.fetch("record_hash"),
        "tool_seq" => tool_record.fetch("seq"),
        "edit_count" => edit_records.length,
        "edit_record_hashes" => edit_records.map { |record| record.fetch("record_hash") },
        "pre_tool_intent_seq" => tool_record.fetch("pre_tool_intent_seq"),
        "pre_tool_intent_hash" => tool_record.fetch("pre_tool_intent_hash")
      }
    end
  end

  def intent_required?(tool)
    kind = tool.fetch("kind")
    return true if %w[shell write edit multi-edit patch].include?(kind)
    return false unless %w[other unknown].include?(kind)

    !Array(tool["file_paths"]).map(&:to_s).reject(&:empty?).empty?
  end

  def append_tool_intent!(state_root, context, event)
    state_root = Pathname.new(state_root)
    StrictModeFdrCycle.with_session_lock!(state_root, context, "pre-tool-intent") do
      path = tool_intent_log_path(state_root, context.fetch("provider"), context.fetch("session_key"))
      tool = event.fetch("tool")
      command = command_projection(tool)
      record = {
        "schema_version" => 1,
        "seq" => last_tool_intent_seq(path) + 1,
        "provider" => context.fetch("provider"),
        "session_key" => context.fetch("session_key"),
        "raw_session_hash" => context.fetch("raw_session_hash"),
        "cwd" => context.fetch("cwd"),
        "project_dir" => context.fetch("project_dir"),
        "turn_marker" => event.fetch("turn_id"),
        "logical_event" => "pre-tool-use",
        "tool_kind" => tool.fetch("kind"),
        "tool_name" => tool.fetch("name"),
        "normalized_command_hash" => command.fetch("hash"),
        "command_hash_source" => command.fetch("source"),
        "normalized_path_list" => normalized_path_list(tool, event.fetch("cwd")),
        "payload_hash" => normalized_payload_hash(event),
        "write_intent" => tool.fetch("write_intent"),
        "ts" => Time.now.utc.iso8601,
        "intent_hash" => ""
      }
      record["intent_hash"] = StrictModeMetadata.hash_record(record, "intent_hash")
      errors = validate_tool_intent_record(record)
      raise "tool intent record invalid: #{errors.join("; ")}" unless errors.empty?

      append_jsonl_with_ledger!(
        state_root,
        context,
        path,
        record,
        target_class: "tool-intent-log",
        related_record_hash: record.fetch("intent_hash")
      )
      record
    end
  end

  def append_tool_record!(state_root, context, event, intent)
    path = tool_log_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    tool = event.fetch("tool")
    command = command_projection(tool)
    record = {
      "schema_version" => 1,
      "seq" => last_tool_seq(path) + 1,
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "turn_marker" => event.fetch("turn_id"),
      "tool_kind" => tool.fetch("kind"),
      "tool_name" => tool.fetch("name"),
      "command_hash" => command.fetch("hash"),
      "command_hash_source" => command.fetch("source"),
      "write_intent" => tool.fetch("write_intent"),
      "payload_hash" => normalized_payload_hash(event),
      "pre_tool_intent_seq" => intent ? intent.fetch("seq") : 0,
      "pre_tool_intent_hash" => intent ? intent.fetch("intent_hash") : ZERO_HASH,
      "ts" => Time.now.utc.iso8601,
      "record_hash" => ""
    }
    record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
    errors = validate_tool_record(record)
    raise "tool record invalid: #{errors.join("; ")}" unless errors.empty?

    append_jsonl_with_ledger!(
      state_root,
      context,
      path,
      record,
      target_class: "tool-log",
      related_record_hash: record.fetch("record_hash")
    )
    record
  end

  def append_edit_record!(state_root, context, event, change)
    path = edit_log_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    normalized = normalize_change(change, Pathname.new(event.fetch("cwd")))
    record = {
      "schema_version" => 1,
      "seq" => last_edit_seq(path) + 1,
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "turn_marker" => event.fetch("turn_id"),
      "path" => normalized.fetch("path"),
      "old_path" => normalized.fetch("old_path"),
      "new_path" => normalized.fetch("new_path"),
      "action" => normalized.fetch("action"),
      "source" => normalized.fetch("source"),
      "ts" => Time.now.utc.iso8601,
      "record_hash" => ""
    }
    record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
    errors = validate_edit_record(record)
    raise "edit record invalid: #{errors.join("; ")}" unless errors.empty?

    append_jsonl_with_ledger!(
      state_root,
      context,
      path,
      record,
      target_class: "edit-log",
      related_record_hash: record.fetch("record_hash")
    )
    record
  end

  def find_matching_intent(state_root, context, event)
    path = tool_intent_log_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    return nil unless trusted_log_ledger_records?(state_root, context, path, "tool-intent-log")

    tool = event.fetch("tool")
    command = command_projection(tool)
    payload_hash = normalized_payload_hash(event)
    candidates = load_jsonl(path).select do |record|
      record.fetch("provider", "") == context.fetch("provider") &&
        record.fetch("session_key", "") == context.fetch("session_key") &&
        record.fetch("raw_session_hash", "") == context.fetch("raw_session_hash") &&
        record.fetch("cwd", "") == context.fetch("cwd") &&
        record.fetch("project_dir", "") == context.fetch("project_dir") &&
        record.fetch("logical_event", "") == "pre-tool-use" &&
        record.fetch("tool_kind", "") == tool.fetch("kind") &&
        record.fetch("tool_name", "") == tool.fetch("name") &&
        record.fetch("normalized_command_hash", "") == command.fetch("hash") &&
        record.fetch("command_hash_source", "") == command.fetch("source") &&
        record.fetch("payload_hash", "") == payload_hash &&
        record.fetch("write_intent", "") == tool.fetch("write_intent")
    end
    candidates.max_by { |record| [record.fetch("ts", ""), record.fetch("seq", 0)] }
  end

  def normalize(payload, provider:, logical_event:, cwd:, project_dir:, payload_hash:)
    StrictModeNormalized.normalize(
      payload,
      provider: provider,
      logical_event: logical_event,
      cwd: cwd,
      project_dir: project_dir,
      payload_sha256: payload_hash
    )
  end

  def session_context(provider:, payload:, cwd:, project_dir:)
    identity = StrictModeFdrCycle.session_identity(provider, payload)
    return nil unless identity

    identity.merge(
      "provider" => provider,
      "cwd" => Pathname.new(cwd).expand_path.cleanpath.to_s,
      "project_dir" => Pathname.new(project_dir).expand_path.cleanpath.to_s
    )
  end

  def command_projection(tool)
    command = tool.fetch("command", "").to_s
    return { "source" => "none", "hash" => ZERO_HASH } if command.empty?

    { "source" => "shell-string", "hash" => Digest::SHA256.hexdigest(command) }
  end

  def normalized_payload_hash(event)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "tool" => event.fetch("tool"),
      "permission" => event.fetch("permission")
    }))
  end

  def normalized_path_list(tool, cwd)
    Array(tool.fetch("file_paths", [])).map do |raw|
      value = raw.to_s
      next "unknown" if value.empty? || value == "unknown"

      normalize_path(value, Pathname.new(cwd))
    end.compact.uniq.sort
  end

  def normalize_change(change, cwd)
    raise "edit change must be an object" unless change.is_a?(Hash)

    action = change.fetch("action")
    source = change.fetch("source")
    raise "edit action invalid" unless EDIT_ACTIONS.include?(action)
    raise "edit source invalid" unless EDIT_SOURCES.include?(source)

    path = normalize_path(change.fetch("path", ""), cwd)
    old_path = optional_normalize_path(change.fetch("old_path", ""), cwd)
    new_path = optional_normalize_path(change.fetch("new_path", ""), cwd)
    case action
    when "create"
      new_path = path if new_path.empty?
      old_path = ""
    when "modify"
      old_path = ""
      new_path = ""
    when "delete"
      old_path = path if old_path.empty?
      new_path = ""
    when "rename"
      raise "rename edit requires old_path and new_path" if old_path.empty? || new_path.empty?
    end

    {
      "path" => path,
      "old_path" => old_path,
      "new_path" => new_path,
      "action" => action,
      "source" => source
    }
  end

  def normalize_path(raw, cwd)
    value = raw.to_s
    raise "path must be non-empty" if value.empty? || value == "unknown"

    path = Pathname.new(value)
    (path.absolute? ? path : cwd.join(path)).cleanpath.to_s
  rescue ArgumentError => e
    raise "path is not normalizable: #{e.message}"
  end

  def optional_normalize_path(raw, cwd)
    value = raw.to_s
    return "" if value.empty?

    normalize_path(value, cwd)
  end

  def tool_intent_log_path(state_root, provider, session_key)
    Pathname.new(state_root).join("tool-intents-#{provider}-#{session_key}.jsonl")
  end

  def tool_log_path(state_root, provider, session_key)
    Pathname.new(state_root).join("tools-#{provider}-#{session_key}.jsonl")
  end

  def edit_log_path(state_root, provider, session_key)
    Pathname.new(state_root).join("edits-#{provider}-#{session_key}.jsonl")
  end

  def load_jsonl(path)
    path = Pathname.new(path)
    raise "#{path}: log must not be a symlink" if path.symlink?
    return [] unless path.exist?
    raise "#{path}: log must be a file" unless path.file?

    path.read.lines.map do |line|
      text = line.strip
      raise "#{path}: blank JSONL line" if text.empty?

      record = JSON.parse(text, object_class: DuplicateKeyHash)
      raise "#{path}: JSONL record must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
  rescue JSON::ParserError, RuntimeError => e
    raise "#{path}: malformed JSONL: #{e.message}"
  end

  def last_tool_intent_seq(path)
    load_jsonl(path).map { |record| record.fetch("seq", 0) }.max || 0
  end

  def last_tool_seq(path)
    load_jsonl(path).map { |record| record.fetch("seq", 0) }.max || 0
  end

  def last_edit_seq(path)
    load_jsonl(path).map { |record| record.fetch("seq", 0) }.max || 0
  end

  def append_jsonl_with_ledger!(state_root, context, path, record, target_class:, related_record_hash:)
    path.dirname.mkpath
    raise "#{path}: log target must not be a symlink" if path.symlink?
    raise "#{path}: log target must be a file" if path.exist? && !path.file?

    old_fingerprint = StrictModeGlobalLedger.fingerprint(path)
    old_size = path.file? && !path.symlink? ? path.size : 0
    new_file = !path.exist?
    flags = File::WRONLY | File::APPEND | File::CREAT
    flags |= File::EXCL if new_file
    flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
    File.open(path.to_s, flags, 0o600) do |file|
      raise "#{path}: log target must be a regular file" unless file.stat.file?

      file.write(JSON.generate(record) + "\n")
    end
    File.chmod(0o600, path) if new_file
    begin
      StrictModeFdrCycle.append_session_ledger!(
        state_root,
        context,
        target_path: path,
        target_class: target_class,
        operation: "append",
        old_fingerprint: old_fingerprint,
        new_fingerprint: StrictModeGlobalLedger.fingerprint(path),
        related_record_hash: related_record_hash,
        writer: "strict-hook"
      )
    rescue RuntimeError, SystemCallError
      if new_file
        FileUtils.rm_f(path) if path.file? && !path.symlink?
      elsif path.file? && !path.symlink?
        File.open(path.to_s, "r+b") { |file| file.truncate(old_size) }
      end
      raise
    end
    record
  end

  def trusted_log_ledger_records?(state_root, context, path, target_class)
    ledger_path = StrictModeFdrCycle.ledger_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    return false unless StrictModeFdrCycle.validate_session_ledger_chain(ledger_path).empty?

    record_hashes = load_jsonl(path).map { |record| record["intent_hash"] || record["record_hash"] }.compact
    return false if record_hashes.empty?

    ledger_records = StrictModeFdrCycle.load_session_ledger_records(ledger_path)
    record_hashes.all? do |hash|
      ledger_records.any? do |ledger|
        ledger.fetch("writer") == "strict-hook" &&
          ledger.fetch("target_class") == target_class &&
          ledger.fetch("operation") == "append" &&
          ledger.fetch("target_path") == Pathname.new(path).to_s &&
          ledger.fetch("related_record_hash") == hash
      end
    end
  rescue RuntimeError, SystemCallError, KeyError
    false
  end

  def validate_tool_intent_record(record)
    errors = exact_field_errors(record, TOOL_INTENT_FIELDS, "tool intent")
    return errors unless errors.empty?

    common_tool_errors(record, hash_field: "intent_hash", command_hash_field: "normalized_command_hash")
  end

  def validate_tool_record(record)
    errors = exact_field_errors(record, TOOL_FIELDS, "tool")
    return errors unless errors.empty?

    errors.concat(common_tool_errors(record, hash_field: "record_hash", command_hash_field: "command_hash"))
    errors << "pre_tool_intent_seq must be non-negative integer" unless record.fetch("pre_tool_intent_seq").is_a?(Integer) && record.fetch("pre_tool_intent_seq") >= 0
    errors << "pre_tool_intent_hash must be lowercase SHA-256" unless sha256?(record.fetch("pre_tool_intent_hash"))
    if record.fetch("pre_tool_intent_seq").zero?
      errors << "zero pre_tool_intent_seq requires zero pre_tool_intent_hash" unless record.fetch("pre_tool_intent_hash") == ZERO_HASH
    else
      errors << "nonzero pre_tool_intent_seq requires nonzero pre_tool_intent_hash" if record.fetch("pre_tool_intent_hash") == ZERO_HASH
    end
    errors
  end

  def common_tool_errors(record, hash_field:, command_hash_field:)
    errors = []
    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "seq must be positive integer" unless record.fetch("seq").is_a?(Integer) && record.fetch("seq") > 0
    errors << "provider invalid" unless %w[claude codex].include?(record.fetch("provider"))
    %w[session_key raw_session_hash cwd project_dir turn_marker tool_kind tool_name command_hash_source write_intent payload_hash].each do |field|
      errors << "#{field} must be a string" unless record.fetch(field).is_a?(String)
    end
    errors << "logical_event invalid" if record.key?("logical_event") && !StrictModeNormalized::LOGICAL_EVENTS.include?(record.fetch("logical_event"))
    errors << "tool_kind invalid" unless StrictModeNormalized::TOOL_KINDS.include?(record.fetch("tool_kind"))
    errors << "command_hash_source invalid" unless COMMAND_HASH_SOURCES.include?(record.fetch("command_hash_source"))
    errors << "write_intent invalid" unless StrictModeNormalized::WRITE_INTENTS.include?(record.fetch("write_intent"))
    %w[raw_session_hash payload_hash].each { |field| errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field)) }
    errors << "#{command_hash_field} must be lowercase SHA-256" unless sha256?(record.fetch(command_hash_field))
    errors << "#{hash_field} must be lowercase SHA-256" unless sha256?(record.fetch(hash_field))
    if sha256?(record.fetch(hash_field)) && StrictModeMetadata.hash_record(record, hash_field) != record.fetch(hash_field)
      errors << "#{hash_field} mismatch"
    end
    if record.fetch("command_hash_source") == "none"
      errors << "#{command_hash_field} must be zero when command source is none" unless record.fetch(command_hash_field) == ZERO_HASH
    else
      errors << "#{command_hash_field} must be nonzero when command source is present" if record.fetch(command_hash_field) == ZERO_HASH
    end
    if record.key?("normalized_path_list")
      paths = record.fetch("normalized_path_list")
      if paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) }
        errors << "normalized_path_list must be sorted and unique" unless paths == paths.uniq.sort
        paths.each do |path|
          errors << "normalized_path_list entries must be absolute paths or unknown" unless path == "unknown" || absolute_path?(path)
        end
      else
        errors << "normalized_path_list must be array"
      end
    end
    errors
  end

  def validate_edit_record(record)
    errors = exact_field_errors(record, EDIT_FIELDS, "edit")
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "seq must be positive integer" unless record.fetch("seq").is_a?(Integer) && record.fetch("seq") > 0
    errors << "provider invalid" unless %w[claude codex].include?(record.fetch("provider"))
    %w[session_key raw_session_hash cwd project_dir turn_marker path old_path new_path action source record_hash].each do |field|
      errors << "#{field} must be a string" unless record.fetch(field).is_a?(String)
    end
    errors << "action invalid" unless EDIT_ACTIONS.include?(record.fetch("action"))
    errors << "source invalid" unless EDIT_SOURCES.include?(record.fetch("source"))
    %w[raw_session_hash record_hash].each { |field| errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field)) }
    errors << "record_hash mismatch" if sha256?(record.fetch("record_hash")) && StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
    errors.concat(validate_edit_path_relation(record))
    errors
  end

  def validate_edit_path_relation(record)
    errors = []
    path = record.fetch("path")
    old_path = record.fetch("old_path")
    new_path = record.fetch("new_path")
    errors << "path must be absolute" unless absolute_path?(path)
    errors << "old_path must be absolute or empty" unless old_path.empty? || absolute_path?(old_path)
    errors << "new_path must be absolute or empty" unless new_path.empty? || absolute_path?(new_path)
    case record.fetch("action")
    when "create"
      errors << "create requires new_path=path" unless new_path == path
      errors << "create forbids old_path" unless old_path.empty?
    when "modify"
      errors << "modify forbids old_path" unless old_path.empty?
      errors << "modify forbids new_path" unless new_path.empty?
    when "delete"
      errors << "delete requires old_path=path" unless old_path == path
      errors << "delete forbids new_path" unless new_path.empty?
    when "rename"
      errors << "rename requires old_path" if old_path.empty?
      errors << "rename requires new_path" if new_path.empty?
    end
    errors
  end

  def exact_field_errors(record, fields, label)
    return ["#{label} record must be a JSON object"] unless record.is_a?(Hash)

    missing = fields - record.keys
    extra = record.keys - fields
    details = []
    details << "missing #{missing.join(", ")}" unless missing.empty?
    details << "extra #{extra.join(", ")}" unless extra.empty?
    details.empty? ? [] : ["#{label} fields mismatch (#{details.join("; ")})"]
  end

  def absolute_path?(value)
    Pathname.new(value).absolute?
  rescue ArgumentError
    false
  end

  def sha256?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end
end
