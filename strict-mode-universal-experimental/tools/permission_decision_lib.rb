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

module StrictModePermissionDecision
  extend self

  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  FIELDS = %w[
    schema_version
    seq
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    turn_marker
    logical_event
    permission_operation
    requested_tool_kind
    decision
    reason_code
    normalized_path_list
    network_tuple_list
    payload_hash
    ts
    previous_record_hash
    record_hash
  ].freeze
  DECISIONS = %w[allow deny].freeze
  REASON_CODES = %w[
    allow-safe
    allow-read-only
    allow-exact-allowlist
    deny-protected-root
    deny-destructive
    deny-network
    deny-filesystem
    deny-broad-scope
    deny-unknown
    deny-invalid-payload
    deny-untrusted-state
    deny-install-integrity
    deny-fixture-missing
    deny-record-failure
    deny-policy
  ].freeze
  NETWORK_TUPLE_FIELDS = %w[scheme host port operation].freeze
  DENY_REASONS = REASON_CODES.select { |reason| reason.start_with?("deny-") }.freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def append_decision_from_payload!(state_root:, provider:, payload:, payload_hash:, cwd:, project_dir:, baseline:)
    raise "permission decision requires payload object" unless payload.is_a?(Hash)
    raise "permission decision requires trusted protected baseline" unless baseline.is_a?(Hash) && baseline.fetch("trusted", false)

    event = StrictModeNormalized.normalize(
      payload,
      provider: provider,
      logical_event: "permission-request",
      cwd: cwd,
      project_dir: project_dir,
      payload_sha256: payload_hash
    )
    context = session_context(provider: provider, payload: payload, cwd: cwd, project_dir: project_dir)
    raise "permission decision requires stable provider session id" unless context

    classification = classify(event, baseline: baseline, raw_tool_input: payload["tool_input"])
    append_decision!(
      state_root,
      context,
      turn_marker: turn_marker(event, context, payload_hash),
      permission_operation: event.fetch("permission").fetch("operation"),
      requested_tool_kind: event.fetch("permission").fetch("requested_tool_kind"),
      decision: classification.fetch("decision"),
      reason_code: classification.fetch("reason_code"),
      normalized_path_list: classification.fetch("normalized_path_list"),
      network_tuple_list: classification.fetch("network_tuple_list"),
      payload_hash: payload_hash
    )
  end

  def classify(event, baseline:, raw_tool_input: nil)
    permission = event.fetch("permission")
    operation = permission.fetch("operation")
    case operation
    when "network"
      classify_network(permission, baseline)
    when "filesystem"
      classify_filesystem(permission, event, baseline)
    when "shell", "write", "tool"
      classify_requested_tool(event, baseline, raw_tool_input: raw_tool_input)
    when "combined"
      classify_combined(permission, event, baseline)
    else
      deny("deny-unknown", path_list(event, permission), [network_tuple(permission.fetch("network"))])
    end
  end

  def classify_network(permission, baseline)
    tuple = network_tuple(permission.fetch("network"))
    tuples = [tuple]
    return deny("deny-network", ["unknown"], tuples) unless concrete_network_tuple?(tuple)
    return deny("deny-network", ["unknown"], tuples) unless tuple.fetch("operation") == "connect"

    allowed = network_allowlist_records(baseline).any? do |record|
      record.fetch("operation") == tuple.fetch("operation") &&
        record.fetch("scheme") == tuple.fetch("scheme") &&
        record.fetch("host") == tuple.fetch("host") &&
        record.fetch("port") == tuple.fetch("port")
    end
    allowed ? allow("allow-exact-allowlist", ["unknown"], tuples) : deny("deny-network", ["unknown"], tuples)
  end

  def classify_filesystem(permission, event, baseline)
    filesystem = permission.fetch("filesystem")
    paths = normalize_paths(filesystem.fetch("paths"), Pathname.new(event.fetch("cwd")))
    return deny("deny-filesystem", ["unknown"], [unknown_network_tuple]) if paths.empty? || paths.include?("unknown")
    return deny("deny-broad-scope", paths, [unknown_network_tuple]) if broad_filesystem_scope?(filesystem)

    protected_path = paths.find { |path| protected_path?(path, baseline) }
    return deny("deny-protected-root", paths, [unknown_network_tuple]) if protected_path

    mode = filesystem.fetch("access_mode")
    case mode
    when "read"
      readable = paths.all? { |path| inside_project?(path, event.fetch("project_dir")) || read_allowlisted?(path, baseline) }
      readable ? allow("allow-read-only", paths, [unknown_network_tuple]) : deny("deny-filesystem", paths, [unknown_network_tuple])
    when "write", "execute", "delete", "chmod"
      writable = paths.all? { |path| inside_project?(path, event.fetch("project_dir")) }
      writable ? allow("allow-safe", paths, [unknown_network_tuple]) : deny("deny-filesystem", paths, [unknown_network_tuple])
    else
      deny("deny-filesystem", paths, [unknown_network_tuple])
    end
  end

  def classify_combined(permission, event, baseline)
    network_result = classify_network(permission, baseline)
    filesystem_result = classify_filesystem(permission, event, baseline)
    return network_result if network_result.fetch("decision") == "deny"
    return filesystem_result if filesystem_result.fetch("decision") == "deny"

    allow(
      "allow-safe",
      filesystem_result.fetch("normalized_path_list"),
      network_result.fetch("network_tuple_list")
    )
  end

  def classify_requested_tool(event, baseline, raw_tool_input: nil)
    tool = event.fetch("tool")
    decision = StrictModeDestructiveGate.classify_tool(
      tool,
      cwd: event.fetch("cwd"),
      project_dir: event.fetch("project_dir"),
      protected_roots: baseline.fetch("protected_roots"),
      protected_inodes: baseline.fetch("protected_inodes"),
      destructive_patterns: baseline.fetch("destructive_patterns"),
      stub_allowlist: baseline.fetch("stub_allowlist"),
      raw_tool_input: raw_tool_input,
      home: baseline.fetch("home"),
      install_root: baseline.fetch("install_root")
    )
    paths = normalize_paths(tool.fetch("file_paths"), Pathname.new(event.fetch("cwd")))
    paths = ["unknown"] if paths.empty?
    if decision.fetch("decision") == "allow"
      paths = [event.fetch("cwd")] if paths.include?("unknown")
      allow("allow-safe", paths, [unknown_network_tuple])
    else
      deny(map_gate_reason(decision.fetch("reason_code")), paths, [unknown_network_tuple])
    end
  end

  def append_decision!(state_root, context, turn_marker:, permission_operation:, requested_tool_kind:, decision:, reason_code:, normalized_path_list:, network_tuple_list:, payload_hash:)
    state_root = Pathname.new(state_root)
    StrictModeFdrCycle.with_session_lock!(state_root, context, "permission-decision") do
      path = permission_decision_path(state_root, context.fetch("provider"), context.fetch("session_key"))
      seq = last_seq(path) + 1
      previous_record_hash = last_record_hash(path)
      record = {
        "schema_version" => 1,
        "seq" => seq,
        "provider" => context.fetch("provider"),
        "session_key" => context.fetch("session_key"),
        "raw_session_hash" => context.fetch("raw_session_hash"),
        "cwd" => context.fetch("cwd"),
        "project_dir" => context.fetch("project_dir"),
        "turn_marker" => turn_marker.to_s,
        "logical_event" => "permission-request",
        "permission_operation" => permission_operation,
        "requested_tool_kind" => requested_tool_kind,
        "decision" => decision,
        "reason_code" => reason_code,
        "normalized_path_list" => normalized_path_list,
        "network_tuple_list" => network_tuple_list,
        "payload_hash" => sha256?(payload_hash) ? payload_hash : ZERO_HASH,
        "ts" => Time.now.utc.iso8601,
        "previous_record_hash" => previous_record_hash,
        "record_hash" => ""
      }
      record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
      errors = validate_record(record, expected_previous_hash: previous_record_hash)
      raise "permission decision record invalid: #{errors.join("; ")}" unless errors.empty?

      append_jsonl_with_ledger!(
        state_root,
        context,
        path,
        record,
        related_record_hash: record.fetch("record_hash")
      )
      record
    end
  end

  def internal_decision(record)
    action = record.fetch("decision") == "deny" ? "block" : "allow"
    {
      "schema_version" => 1,
      "action" => action,
      "reason" => action == "block" ? "strict-mode denied permission request: #{record.fetch("reason_code")}" : "",
      "severity" => action == "block" ? "error" : "info",
      "additional_context" => "",
      "metadata" => {
        "logical_event" => "permission-request",
        "reason_code" => record.fetch("reason_code"),
        "permission_record_hash" => record.fetch("record_hash"),
        "permission_operation" => record.fetch("permission_operation"),
        "requested_tool_kind" => record.fetch("requested_tool_kind")
      }
    }
  end

  def record_failure_decision(message)
    {
      "schema_version" => 1,
      "action" => "block",
      "reason" => "strict-mode denied permission request: deny-record-failure (#{message})",
      "severity" => "critical",
      "additional_context" => "",
      "metadata" => {
        "logical_event" => "permission-request",
        "reason_code" => "deny-record-failure"
      }
    }
  end

  def permission_decision_path(state_root, provider, session_key)
    Pathname.new(state_root).join("permission-decisions-#{provider}-#{session_key}.jsonl")
  end

  def load_records(path)
    path = Pathname.new(path)
    return [] unless path.exist?
    raise "#{path}: permission decision log must be a file" unless path.file?
    raise "#{path}: permission decision log must not be a symlink" if path.symlink?

    records = path.read.lines.each_with_index.map do |line, index|
      text = line.strip
      raise "#{path}: blank permission decision line #{index + 1}" if text.empty?

      record = JSON.parse(text, object_class: DuplicateKeyHash)
      raise "#{path}: permission decision line #{index + 1} must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
    validate_chain_records!(path, records)
    records
  end

  def validate_chain(path)
    validate_chain_records!(path, load_records_without_chain(path))
    []
  rescue JSON::ParserError, RuntimeError => e
    [e.message]
  end

  def validate_record(record, expected_previous_hash: nil)
    return ["permission decision record must be a JSON object"] unless record.is_a?(Hash)

    errors = []
    field_errors(record, FIELDS, "permission decision").each { |error| errors << error }
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "seq must be a positive integer" unless record.fetch("seq").is_a?(Integer) && record.fetch("seq") > 0
    errors << "provider invalid" unless %w[claude codex].include?(record.fetch("provider"))
    %w[session_key raw_session_hash cwd project_dir turn_marker logical_event permission_operation requested_tool_kind decision reason_code payload_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be a string" unless record.fetch(field).is_a?(String)
    end
    errors << "logical_event must be permission-request" unless record.fetch("logical_event") == "permission-request"
    errors << "permission_operation invalid" unless StrictModeNormalized::PERMISSION_OPERATIONS.include?(record.fetch("permission_operation"))
    errors << "requested_tool_kind invalid" unless StrictModeNormalized::TOOL_KINDS.include?(record.fetch("requested_tool_kind"))
    errors << "decision invalid" unless DECISIONS.include?(record.fetch("decision"))
    errors << "reason_code invalid" unless REASON_CODES.include?(record.fetch("reason_code"))
    errors << "allow decision requires allow reason_code" if record.fetch("decision") == "allow" && !record.fetch("reason_code").start_with?("allow-")
    errors << "deny decision requires deny reason_code" if record.fetch("decision") == "deny" && !DENY_REASONS.include?(record.fetch("reason_code"))
    %w[raw_session_hash payload_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "previous_record_hash mismatch" if expected_previous_hash && record.fetch("previous_record_hash") != expected_previous_hash
    if sha256?(record.fetch("record_hash")) && StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
      errors << "record_hash mismatch"
    end
    errors.concat(validate_paths(record))
    errors.concat(validate_network_tuples(record))
    errors
  end

  def allow(reason_code, normalized_path_list, network_tuple_list)
    { "decision" => "allow", "reason_code" => reason_code, "normalized_path_list" => normalized_path_list, "network_tuple_list" => network_tuple_list }
  end

  def deny(reason_code, normalized_path_list, network_tuple_list)
    { "decision" => "deny", "reason_code" => reason_code, "normalized_path_list" => normalized_path_list, "network_tuple_list" => network_tuple_list }
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

  def turn_marker(event, context, payload_hash)
    explicit = event.fetch("turn_id", "")
    return explicit unless explicit.empty?

    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "provider" => context.fetch("provider"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "request_id" => event.fetch("permission").fetch("request_id"),
      "payload_hash" => payload_hash
    }))
  end

  def path_list(event, permission)
    paths = permission.fetch("filesystem").fetch("paths")
    normalized = normalize_paths(paths, Pathname.new(event.fetch("cwd")))
    normalized.empty? ? ["unknown"] : normalized
  end

  def normalize_paths(paths, cwd)
    Array(paths).map do |raw|
      value = raw.to_s
      next "unknown" if value.empty? || value == "unknown"

      path = Pathname.new(value)
      (path.absolute? ? path : cwd.join(path)).cleanpath.to_s
    rescue ArgumentError
      "unknown"
    end.uniq.sort
  end

  def network_tuple(network)
    {
      "scheme" => network.fetch("scheme"),
      "host" => network.fetch("host"),
      "port" => network.fetch("port"),
      "operation" => network.fetch("operation")
    }
  end

  def unknown_network_tuple
    { "scheme" => "unknown", "host" => "unknown", "port" => "unknown", "operation" => "unknown" }
  end

  def concrete_network_tuple?(tuple)
    %w[scheme host operation].all? { |field| tuple.fetch(field).is_a?(String) && tuple.fetch(field) != "unknown" && !tuple.fetch(field).empty? } &&
      tuple.fetch("port").is_a?(Integer) &&
      tuple.fetch("port").between?(1, 65_535)
  end

  def network_allowlist_records(baseline)
    baseline.fetch("config_results").fetch("network-allowlist.txt", { "records" => [] }).fetch("records")
  end

  def read_allowlist_records(baseline)
    baseline.fetch("config_results").fetch("filesystem-read-allowlist.txt", { "records" => [] }).fetch("records")
  end

  def broad_filesystem_scope?(filesystem)
    %w[home root unknown].include?(filesystem.fetch("scope")) ||
      filesystem.fetch("recursive") == "unknown"
  end

  def protected_path?(path, baseline)
    path_name = Pathname.new(path)
    baseline.fetch("protected_roots").any? { |root| StrictModeDestructiveGate.path_inside?(path, root.to_s) } ||
      StrictModeDestructiveGate.symlink_parent_component?(path_name) ||
      path_name.symlink? ||
      StrictModeDestructiveGate.protected_inode_path?(path_name, baseline.fetch("protected_inodes"))
  end

  def inside_project?(path, project_dir)
    StrictModeDestructiveGate.path_inside?(path, Pathname.new(project_dir).cleanpath.to_s)
  end

  def read_allowlisted?(path, baseline)
    read_allowlist_records(baseline).any? do |record|
      allowed_path = record.fetch("path")
      record.fetch("scope") == "tree" ? StrictModeDestructiveGate.path_inside?(path, allowed_path) : path == allowed_path
    end
  end

  def map_gate_reason(reason_code)
    case reason_code
    when "protected-root", "protected-runtime-execution"
      "deny-protected-root"
    when "destructive-command"
      "deny-destructive"
    when "unknown-write-target", "protected-target-unknown", "shell-command-missing", "shell-parse-error"
      "deny-filesystem"
    when "invalid-identity"
      "deny-invalid-payload"
    when "trusted-import-invalid", "trusted-import-unavailable", "stub-detected"
      "deny-policy"
    else
      "deny-unknown"
    end
  end

  def append_jsonl_with_ledger!(state_root, context, path, record, related_record_hash:)
    path.dirname.mkpath
    old_fingerprint = StrictModeGlobalLedger.fingerprint(path)
    old_size = path.file? && !path.symlink? ? path.size : 0
    new_file = !path.exist?
    File.open(path.to_s, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.write(JSON.generate(record) + "\n") }
    File.chmod(0o600, path) if new_file
    begin
      StrictModeFdrCycle.append_session_ledger!(
        state_root,
        context,
        target_path: path,
        target_class: "permission-decision-log",
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

  def load_records_without_chain(path)
    path = Pathname.new(path)
    return [] unless path.exist?
    raise "#{path}: permission decision log must be a file" unless path.file?
    raise "#{path}: permission decision log must not be a symlink" if path.symlink?

    path.read.lines.map do |line|
      record = JSON.parse(line, object_class: DuplicateKeyHash)
      raise "#{path}: permission decision JSONL record must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
  end

  def validate_chain_records!(path, records)
    previous = ZERO_HASH
    records.each_with_index do |record, index|
      errors = validate_record(record, expected_previous_hash: previous)
      raise "#{path}: invalid permission decision line #{index + 1}: #{errors.join("; ")}" unless errors.empty?
      raise "#{path}: permission decision seq must increase by one" unless record.fetch("seq") == index + 1

      previous = record.fetch("record_hash")
    end
  end

  def last_seq(path)
    load_records(path).map { |record| record.fetch("seq") }.max || 0
  end

  def last_record_hash(path)
    records = load_records(path)
    records.empty? ? ZERO_HASH : records.last.fetch("record_hash")
  end

  def validate_paths(record)
    paths = record.fetch("normalized_path_list")
    return ["normalized_path_list must be a non-empty array of strings"] unless paths.is_a?(Array) && !paths.empty? && paths.all? { |path| path.is_a?(String) && !path.empty? }

    errors = []
    if record.fetch("decision") == "allow"
      paths.each do |path|
        errors << "allow path entries must be absolute" unless path == "unknown" || Pathname.new(path).absolute?
      rescue ArgumentError
        errors << "allow path entry is not normalizable"
      end
      errors << "allow path entries must not use unknown sentinel" if paths.include?("unknown") && record.fetch("permission_operation") != "network"
    end
    errors
  end

  def validate_network_tuples(record)
    tuples = record.fetch("network_tuple_list")
    return ["network_tuple_list must be a non-empty array"] unless tuples.is_a?(Array) && !tuples.empty?

    errors = []
    tuples.each do |tuple|
      unless tuple.is_a?(Hash) && tuple.keys.sort == NETWORK_TUPLE_FIELDS.sort
        errors << "network tuple fields must be exact"
        next
      end
      %w[scheme host operation].each do |field|
        errors << "network tuple #{field} must be a string" unless tuple.fetch(field).is_a?(String)
      end
      port = tuple.fetch("port")
      unless port == "unknown" || (port.is_a?(Integer) && port.between?(1, 65_535))
        errors << "network tuple port must be integer 1..65535 or unknown"
      end
      next unless record.fetch("decision") == "allow" && record.fetch("permission_operation") == "network"

      errors << "allow network tuple must be concrete" unless concrete_network_tuple?(tuple)
    end
    errors
  end

  def field_errors(record, fields, label)
    missing = fields - record.keys
    extra = record.keys - fields
    errors = []
    details = []
    details << "missing #{missing.join(", ")}" unless missing.empty?
    details << "extra #{extra.join(", ")}" unless extra.empty?
    errors << "#{label} fields mismatch (#{details.join("; ")})" unless details.empty?
    errors
  end

  def sha256?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end
end
