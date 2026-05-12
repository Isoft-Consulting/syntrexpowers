# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"

require_relative "destructive_gate_lib"
require_relative "fdr_cycle_lib"
require_relative "global_ledger_lib"
require_relative "metadata_lib"
require_relative "normalized_event_lib"

class StrictModeFdrImport
  ZERO_HASH = StrictModeFdrCycle::ZERO_HASH
  SHA256_PATTERN = /\A[a-f0-9]{64}\z/.freeze
  DEFAULT_SOURCE_MAX_BYTES = 1_048_576
  ARTIFACT_FIELDS = %w[
    schema_version
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    review_generated_at
    imported_at
    turn_marker
    coverage_cutoff_tool_intent_seq
    coverage_cutoff_tool_seq
    coverage_cutoff_edit_seq
    tool_intent_seq_min
    tool_intent_seq_max
    tool_intent_seq_list
    tool_intent_log_digest
    tool_seq_min
    tool_seq_max
    tool_seq_list
    tool_log_digest
    edit_seq_min
    edit_seq_max
    edit_seq_list
    edit_log_digest
    edited_paths
    deleted_paths
    renamed_paths
    findings
    finding_count
    verdict
    reviewer
    import_provenance
  ].freeze
  PROVENANCE_FIELDS = %w[
    schema_version
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    source_path
    source_realpath
    source_fingerprint
    source_size_bytes
    argv
    command_hash
    command_hash_source
    import_intent_seq
    import_intent_hash
    imported_artifact_hash
    coverage_cutoff_tool_intent_seq
    coverage_cutoff_tool_seq
    coverage_cutoff_edit_seq
  ].freeze
  FINDING_FIELDS = %w[severity path line claim evidence impact recommendation].freeze
  SEVERITIES = %w[critical high medium low info].freeze
  VERDICTS = %w[clean findings incomplete].freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  class ImportError < RuntimeError
    attr_reader :reason_code

    def initialize(reason_code, message)
      @reason_code = reason_code
      super(message)
    end
  end

  def self.import!(source_arg:, install_root:, state_root:, cwd:, project_dir:)
    install_root = Pathname.new(install_root).expand_path.cleanpath
    state_root = Pathname.new(state_root).expand_path.cleanpath
    cwd = Pathname.new(cwd).expand_path.cleanpath
    project_dir = Pathname.new(project_dir).expand_path.cleanpath
    raise "cwd must be equal to or inside project_dir" unless path_inside?(cwd.to_s, project_dir.to_s)

    source = validate_source!(source_arg, cwd: cwd, project_dir: project_dir)
    intent = find_matching_intent!(state_root, install_root, source_arg, source, cwd, project_dir)
    context = intent_context(intent.fetch("record"))
    StrictModeFdrCycle.with_session_lock!(state_root, context, "fdr-import") do
      source_doc = parse_source_document(source.fetch("realpath"))
      now = Time.now.utc
      review_time = source_doc.fetch("review_generated_at")
      artifact = build_artifact(
        source_doc,
        context: context,
        source: source,
        source_arg: source_arg,
        install_root: install_root,
        import_intent: intent.fetch("record"),
        review_generated_at: review_time,
        imported_at: now
      )
      artifact_path = artifact_path(state_root, context.fetch("provider"), context.fetch("session_key"))
      write_artifact_with_ledger!(state_root, context, artifact_path, artifact)
    end
  rescue ImportError
    raise
  rescue RuntimeError, SystemCallError, ArgumentError, KeyError => e
    raise ImportError.new("trusted-import-invalid", e.message)
  end

  def self.append_import_intent_from_payload!(state_root:, install_root:, provider:, logical_event:, payload:, payload_hash:, cwd:, project_dir:)
    return nil unless logical_event == "pre-tool-use"
    return nil unless payload.is_a?(Hash)

    event = StrictModeNormalized.normalize(
      payload,
      provider: provider,
      logical_event: logical_event,
      cwd: cwd,
      project_dir: project_dir,
      payload_sha256: payload_hash
    )
    tool = event.fetch("tool")
    return nil unless tool.fetch("kind") == "shell"
    return nil unless tool.fetch("command").is_a?(String) && !tool.fetch("command").empty?

    tokens = StrictModeDestructiveGate.shell_tokens(tool.fetch("command"))
    return nil if tokens.fetch("error")

    words = tokens.fetch("words")
    import_args = trusted_import_words(words, tokens, install_root: install_root, cwd: cwd)
    return nil unless import_args

    source = validate_source!(import_args.fetch("source_arg"), cwd: Pathname.new(cwd), project_dir: Pathname.new(project_dir))
    identity = StrictModeFdrCycle.session_identity(provider, payload)
    raise "trusted import requires stable provider session id" unless identity

    context = {
      "provider" => provider,
      "session_key" => identity.fetch("session_key"),
      "raw_session_hash" => identity.fetch("raw_session_hash"),
      "cwd" => Pathname.new(cwd).to_s,
      "project_dir" => Pathname.new(project_dir).to_s
    }
    append_import_intent!(
      state_root,
      context,
      turn_marker: event.fetch("turn_id", ""),
      install_root: Pathname.new(install_root),
      source_arg: import_args.fetch("source_arg"),
      source_realpath: source.fetch("realpath"),
      payload_hash: payload_hash
    )
  end

  def self.trusted_import_words(words, tokens, install_root:, cwd:)
    return nil unless words.length == 4 && words[1] == "import" && words[2] == "--"
    return nil unless tokens.fetch("ops").empty?

    strict_fdr = Pathname.new(install_root).join("active/bin/strict-fdr").cleanpath.to_s
    executable = StrictModeDestructiveGate.normalize_tool_path(words[0], Pathname.new(cwd))
    return nil unless executable == strict_fdr

    { "source_arg" => words[3] }
  end

  def self.append_import_intent!(state_root, context, turn_marker:, install_root:, source_arg:, source_realpath:, payload_hash:)
    state_root = Pathname.new(state_root)
    StrictModeFdrCycle.with_session_lock!(state_root, context, "pre-tool-intent") do
      path = tool_intent_log_path(state_root, context.fetch("provider"), context.fetch("session_key"))
      seq = last_tool_intent_seq(path) + 1
      argv = import_argv(install_root, source_arg)
      command_hash = command_hash(argv, context)
      record = {
        "schema_version" => 1,
        "seq" => seq,
        "provider" => context.fetch("provider"),
        "session_key" => context.fetch("session_key"),
        "raw_session_hash" => context.fetch("raw_session_hash"),
        "cwd" => context.fetch("cwd"),
        "project_dir" => context.fetch("project_dir"),
        "turn_marker" => turn_marker.to_s,
        "logical_event" => "pre-tool-use",
        "tool_kind" => "shell",
        "tool_name" => "exec_command",
        "normalized_command_hash" => command_hash,
        "command_hash_source" => "trusted-import-argv",
        "normalized_path_list" => [source_realpath.to_s],
        "payload_hash" => sha256?(payload_hash) ? payload_hash : ZERO_HASH,
        "write_intent" => "write",
        "ts" => Time.now.utc.iso8601,
        "intent_hash" => ""
      }
      record["intent_hash"] = StrictModeMetadata.hash_record(record, "intent_hash")
      append_jsonl_with_ledger!(
        state_root,
        context,
        path,
        record,
        target_class: "tool-intent-log",
        writer: "strict-hook",
        related_record_hash: record.fetch("intent_hash")
      )
      record
    end
  end

  def self.validate_source!(source_arg, cwd:, project_dir:)
    source = normalize_path(source_arg, cwd)
    raise "source path is not normalizable" unless source
    raise "source path must be inside project" unless path_inside?(source.to_s, project_dir.to_s)
    raise "source path has symlink component" if symlink_parent_component?(source)
    raise "source path must be an existing regular file" unless source.file? && !source.symlink?

    stat = source.lstat
    raise "source path must not be a protected hardlink candidate" if stat.nlink > 1
    max_bytes = source_max_bytes
    raise "source file exceeds STRICT_FDR_SOURCE_MAX_BYTES" if stat.size > max_bytes

    realpath = source.realpath
    relative = realpath.relative_path_from(project_dir.realpath).to_s
    fingerprint_subject = {
      "source_realpath" => realpath.to_s,
      "dev" => stat.dev,
      "inode" => stat.ino,
      "mode" => stat.mode,
      "size_bytes" => stat.size,
      "mtime_ns" => (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec,
      "content_sha256" => Digest::SHA256.file(source).hexdigest
    }
    {
      "source_path" => relative,
      "realpath" => realpath.to_s,
      "fingerprint" => Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(fingerprint_subject)),
      "size_bytes" => stat.size
    }
  rescue ArgumentError
    raise "source path is not normalizable"
  end

  def self.parse_source_document(path)
    text = Pathname.new(path).read(source_max_bytes + 1)
    raise "source file exceeds STRICT_FDR_SOURCE_MAX_BYTES" if text.bytesize > source_max_bytes

    raw = extract_json_source(text)
    verdict = raw.fetch("verdict", "")
    raise "source verdict invalid" unless VERDICTS.include?(verdict)

    findings = normalize_findings(raw.fetch("findings", []))
    raise "clean verdict cannot include findings" if verdict == "clean" && findings.any?
    raise "findings verdict requires at least one finding" if verdict == "findings" && findings.empty?

    {
      "review_generated_at" => normalize_time(raw["review_generated_at"] || Time.now.utc.iso8601),
      "reviewer" => bounded_text(raw.fetch("reviewer", ""), 128),
      "verdict" => verdict,
      "findings" => findings
    }
  end

  def self.extract_json_source(text)
    match = text.match(/```json strict-fdr-v1[ \t]*\n(?<json>.*?)\n```/m)
    json = match ? match[:json] : text.strip
    raise "source must contain a json strict-fdr-v1 block" unless json.start_with?("{")

    parsed = JSON.parse(json, object_class: DuplicateKeyHash)
    raise "source JSON root must be an object" unless parsed.is_a?(Hash)

    JSON.parse(JSON.generate(parsed))
  rescue JSON::ParserError, RuntimeError => e
    raise "source JSON invalid: #{e.message}"
  end

  def self.normalize_findings(value)
    raise "findings must be an array" unless value.is_a?(Array)

    value.map do |finding|
      raise "finding must be an object" unless finding.is_a?(Hash)

      severity = finding.fetch("severity", "")
      path = finding.fetch("path", "")
      line = finding.fetch("line", 0)
      claim = finding.fetch("claim", finding.fetch("message", ""))
      impact = finding.fetch("impact", finding.fetch("source", "review finding"))
      normalized = {
        "severity" => severity,
        "path" => path,
        "line" => line,
        "claim" => bounded_required_text(claim, "claim"),
        "evidence" => bounded_required_text(finding.fetch("evidence", ""), "evidence"),
        "impact" => bounded_required_text(impact, "impact"),
        "recommendation" => bounded_required_text(finding.fetch("recommendation", ""), "recommendation")
      }
      validate_finding!(normalized)
      normalized
    end
  end

  def self.validate_finding!(finding)
    raise "finding fields invalid" unless finding.keys.sort == FINDING_FIELDS.sort
    raise "finding severity invalid" unless SEVERITIES.include?(finding.fetch("severity"))
    raise "finding path must be a string" unless finding.fetch("path").is_a?(String)
    raise "finding line must be a non-negative integer" unless finding.fetch("line").is_a?(Integer) && finding.fetch("line") >= 0
    raise "finding empty path requires line 0" if finding.fetch("path").empty? && finding.fetch("line") != 0
    %w[claim evidence impact recommendation].each do |field|
      raise "finding #{field} must be non-empty" if finding.fetch(field).empty?
    end
  end

  def self.build_artifact(source_doc, context:, source:, source_arg:, install_root:, import_intent:, review_generated_at:, imported_at:)
    tool_intent_seq_list = []
    tool_seq_list = []
    edit_seq_list = []
    artifact = {
      "schema_version" => 1,
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "review_generated_at" => review_generated_at.iso8601,
      "imported_at" => imported_at.iso8601,
      "turn_marker" => import_intent.fetch("turn_marker", ""),
      "coverage_cutoff_tool_intent_seq" => import_intent.fetch("seq"),
      "coverage_cutoff_tool_seq" => 0,
      "coverage_cutoff_edit_seq" => 0,
      "tool_intent_seq_min" => 0,
      "tool_intent_seq_max" => 0,
      "tool_intent_seq_list" => tool_intent_seq_list,
      "tool_intent_log_digest" => digest_json_array([]),
      "tool_seq_min" => 0,
      "tool_seq_max" => 0,
      "tool_seq_list" => tool_seq_list,
      "tool_log_digest" => digest_json_array([]),
      "edit_seq_min" => 0,
      "edit_seq_max" => 0,
      "edit_seq_list" => edit_seq_list,
      "edit_log_digest" => digest_json_array([]),
      "edited_paths" => [],
      "deleted_paths" => [],
      "renamed_paths" => [],
      "findings" => source_doc.fetch("findings"),
      "finding_count" => source_doc.fetch("findings").length,
      "verdict" => source_doc.fetch("verdict"),
      "reviewer" => source_doc.fetch("reviewer"),
      "import_provenance" => {
        "schema_version" => 1,
        "provider" => context.fetch("provider"),
        "session_key" => context.fetch("session_key"),
        "raw_session_hash" => context.fetch("raw_session_hash"),
        "cwd" => context.fetch("cwd"),
        "project_dir" => context.fetch("project_dir"),
        "source_path" => source.fetch("source_path"),
        "source_realpath" => source.fetch("realpath"),
        "source_fingerprint" => source.fetch("fingerprint"),
        "source_size_bytes" => source.fetch("size_bytes"),
        "argv" => import_argv(install_root, source_arg),
        "command_hash" => import_intent.fetch("normalized_command_hash"),
        "command_hash_source" => "trusted-import-argv",
        "import_intent_seq" => import_intent.fetch("seq"),
        "import_intent_hash" => import_intent.fetch("intent_hash"),
        "imported_artifact_hash" => "",
        "coverage_cutoff_tool_intent_seq" => import_intent.fetch("seq"),
        "coverage_cutoff_tool_seq" => 0,
        "coverage_cutoff_edit_seq" => 0
      }
    }
    validate_artifact!(artifact)
    artifact.fetch("import_provenance")["imported_artifact_hash"] = artifact_hash(artifact)
    validate_artifact!(artifact)
    artifact
  end

  def self.write_artifact_with_ledger!(state_root, context, artifact_path, artifact)
    old_fingerprint = StrictModeGlobalLedger.fingerprint(artifact_path)
    old_state = capture_existing_path_state(artifact_path)
    artifact_path.dirname.mkpath
    rendered = render_artifact(artifact)
    tmp = artifact_path.dirname.join(".#{artifact_path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
    tmp.write(rendered)
    File.chmod(0o600, tmp)
    File.rename(tmp, artifact_path)
    new_fingerprint = StrictModeGlobalLedger.fingerprint(artifact_path)
    ledger = StrictModeFdrCycle.append_session_ledger!(
      state_root,
      context,
      target_path: artifact_path,
      target_class: "fdr-artifact",
      operation: StrictModeGlobalLedger.operation_for(old_fingerprint, new_fingerprint),
      old_fingerprint: old_fingerprint,
      new_fingerprint: new_fingerprint,
      related_record_hash: artifact.fetch("import_provenance").fetch("imported_artifact_hash"),
      writer: "strict-fdr"
    )
    {
      "schema_version" => 1,
      "mode" => "trusted-import",
      "decision" => "allow",
      "artifact_path" => artifact_path.to_s,
      "imported_artifact_hash" => artifact.fetch("import_provenance").fetch("imported_artifact_hash"),
      "ledger_record_hash" => ledger.fetch("record_hash")
    }
  rescue RuntimeError, SystemCallError
    restore_path_state(artifact_path, old_state)
    raise
  end

  def self.find_matching_intent!(state_root, install_root, source_arg, source, cwd, project_dir)
    matches = Dir[Pathname.new(state_root).join("tool-intents-*.jsonl").to_s].flat_map do |path|
      load_jsonl(path).select do |record|
        next false unless record.fetch("command_hash_source", "") == "trusted-import-argv"
        next false unless record.fetch("cwd", "") == cwd.to_s && record.fetch("project_dir", "") == project_dir.to_s
        next false unless record.fetch("normalized_path_list", []) == [source.fetch("realpath")]
        next false unless trusted_intent_ledger_record?(state_root, path, record)

        context = intent_context(record)
        record.fetch("normalized_command_hash", "") == command_hash(import_argv(install_root, source_arg), context)
      end.map { |record| { "path" => path, "record" => record } }
    end
    raise ImportError.new("trusted-import-intent-missing", "matching trusted import intent not found") if matches.empty?

    matches.max_by { |match| [match.fetch("record").fetch("ts", ""), match.fetch("record").fetch("seq", 0)] }
  end

  def self.trusted_intent_ledger_record?(state_root, intent_path, record)
    ledger_path = StrictModeFdrCycle.ledger_path(state_root, record.fetch("provider"), record.fetch("session_key"))
    return false unless StrictModeFdrCycle.validate_session_ledger_chain(ledger_path).empty?

    StrictModeFdrCycle.load_session_ledger_records(ledger_path).any? do |ledger|
      ledger.fetch("writer") == "strict-hook" &&
        ledger.fetch("target_class") == "tool-intent-log" &&
        ledger.fetch("operation") == "append" &&
        ledger.fetch("target_path") == Pathname.new(intent_path).to_s &&
        ledger.fetch("related_record_hash") == record.fetch("intent_hash")
    end
  rescue RuntimeError, SystemCallError, KeyError
    false
  end

  def self.intent_context(record)
    {
      "provider" => record.fetch("provider"),
      "session_key" => record.fetch("session_key"),
      "raw_session_hash" => record.fetch("raw_session_hash"),
      "cwd" => record.fetch("cwd"),
      "project_dir" => record.fetch("project_dir")
    }
  end

  def self.validate_artifact!(artifact)
    raise "artifact fields mismatch" unless artifact.keys.sort == ARTIFACT_FIELDS.sort
    raise "schema_version must be 1" unless artifact.fetch("schema_version") == 1
    raise "provider invalid" unless %w[claude codex].include?(artifact.fetch("provider"))
    raise "verdict invalid" unless VERDICTS.include?(artifact.fetch("verdict"))
    raise "finding_count mismatch" unless artifact.fetch("finding_count") == artifact.fetch("findings").length
    raise "clean verdict cannot include findings" if artifact.fetch("verdict") == "clean" && artifact.fetch("finding_count") != 0
    raise "findings verdict requires findings" if artifact.fetch("verdict") == "findings" && artifact.fetch("finding_count").zero?
    %w[session_key raw_session_hash cwd project_dir review_generated_at imported_at turn_marker reviewer].each do |field|
      raise "#{field} must be a string" unless artifact.fetch(field).is_a?(String)
    end
    %w[coverage_cutoff_tool_intent_seq coverage_cutoff_tool_seq coverage_cutoff_edit_seq tool_intent_seq_min tool_intent_seq_max tool_seq_min tool_seq_max edit_seq_min edit_seq_max finding_count].each do |field|
      raise "#{field} must be non-negative integer" unless artifact.fetch(field).is_a?(Integer) && artifact.fetch(field) >= 0
    end
    %w[tool_intent_log_digest tool_log_digest edit_log_digest raw_session_hash].each do |field|
      raise "#{field} must be lowercase SHA-256" unless sha256?(artifact.fetch(field))
    end
    %w[tool_intent_seq_list tool_seq_list edit_seq_list edited_paths deleted_paths renamed_paths findings].each do |field|
      raise "#{field} must be an array" unless artifact.fetch(field).is_a?(Array)
    end
    artifact.fetch("findings").each { |finding| validate_finding!(finding) }
    validate_provenance!(artifact.fetch("import_provenance"), artifact)
  end

  def self.validate_provenance!(record, artifact)
    raise "import_provenance must be an object" unless record.is_a?(Hash)
    raise "import_provenance fields mismatch" unless record.keys.sort == PROVENANCE_FIELDS.sort
    raise "import_provenance schema_version must be 1" unless record.fetch("schema_version") == 1
    %w[provider session_key raw_session_hash cwd project_dir].each do |field|
      raise "import_provenance #{field} mismatch" unless record.fetch(field) == artifact.fetch(field)
    end
    raise "source_size_bytes must be non-negative integer" unless record.fetch("source_size_bytes").is_a?(Integer) && record.fetch("source_size_bytes") >= 0
    %w[source_path source_realpath command_hash_source].each do |field|
      raise "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty?
    end
    %w[source_fingerprint command_hash import_intent_hash imported_artifact_hash].each do |field|
      value = record.fetch(field)
      next if field == "imported_artifact_hash" && value == ""
      raise "#{field} must be lowercase SHA-256" unless sha256?(value)
    end
    raise "command_hash_source invalid" unless record.fetch("command_hash_source") == "trusted-import-argv"
    raise "argv shape invalid" unless record.fetch("argv").is_a?(Array) && record.fetch("argv").length == 4 && record.fetch("argv")[1, 2] == %w[import --]
    %w[coverage_cutoff_tool_intent_seq coverage_cutoff_tool_seq coverage_cutoff_edit_seq].each do |field|
      raise "import_provenance #{field} mismatch" unless record.fetch(field) == artifact.fetch(field)
    end
  end

  def self.artifact_hash(artifact)
    copy = JSON.parse(JSON.generate(artifact))
    copy.fetch("import_provenance")["imported_artifact_hash"] = ""
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(copy))
  end

  def self.render_artifact(artifact)
    "```json strict-fdr-v1\n#{JSON.pretty_generate(artifact)}\n```\n"
  end

  def self.tool_intent_log_path(state_root, provider, session_key)
    Pathname.new(state_root).join("tool-intents-#{provider}-#{session_key}.jsonl")
  end

  def self.artifact_path(state_root, provider, session_key)
    Pathname.new(state_root).join("fdr-#{provider}-#{session_key}.md")
  end

  def self.import_argv(install_root, source_arg)
    [Pathname.new(install_root).join("active/bin/strict-fdr").cleanpath.to_s, "import", "--", source_arg.to_s]
  end

  def self.command_hash(argv, context)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "argv" => argv,
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "command_hash_source" => "trusted-import-argv"
    }))
  end

  def self.append_jsonl_with_ledger!(state_root, context, path, record, target_class:, writer:, related_record_hash:)
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
        target_class: target_class,
        operation: "append",
        old_fingerprint: old_fingerprint,
        new_fingerprint: StrictModeGlobalLedger.fingerprint(path),
        related_record_hash: related_record_hash,
        writer: writer
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

  def self.capture_existing_path_state(path)
    path = Pathname.new(path)
    return { "kind" => "missing" } unless path.exist? || path.symlink?
    return { "kind" => "symlink", "target" => path.readlink.to_s } if path.symlink?
    return { "kind" => "file", "content" => path.binread, "mode" => path.lstat.mode & 0o777 } if path.file?

    { "kind" => "other" }
  end

  def self.restore_path_state(path, state)
    path = Pathname.new(path)
    case state.fetch("kind")
    when "missing"
      FileUtils.rm_f(path) if path.file? || path.symlink?
    when "file"
      tmp = path.dirname.join(".#{path.basename}.rollback-#{$$}-#{SecureRandom.hex(4)}")
      tmp.binwrite(state.fetch("content"))
      File.chmod(state.fetch("mode"), tmp)
      File.rename(tmp, path)
    when "symlink"
      FileUtils.rm_f(path) if path.file? || path.symlink?
      File.symlink(state.fetch("target"), path.to_s)
    when "other"
      FileUtils.rm_f(path) if path.file? || path.symlink?
    end
  rescue SystemCallError
    nil
  end

  def self.last_tool_intent_seq(path)
    load_jsonl(path).map { |record| record.fetch("seq", 0) }.max || 0
  end

  def self.load_jsonl(path)
    path = Pathname.new(path)
    return [] unless path.file?

    path.read.lines.map do |line|
      record = JSON.parse(line, object_class: DuplicateKeyHash)
      raise "#{path}: JSONL record must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
  rescue JSON::ParserError, RuntimeError => e
    raise "#{path}: malformed JSONL: #{e.message}"
  end

  def self.normalize_path(raw, cwd)
    path = Pathname.new(raw.to_s)
    (path.absolute? ? path : cwd.join(path)).cleanpath
  rescue ArgumentError
    nil
  end

  def self.symlink_parent_component?(path)
    current = Pathname.new(path).absolute? ? Pathname.new("/") : Pathname.new(".")
    parts = Pathname.new(path).each_filename.to_a
    parts[0...-1].each do |part|
      current = current.join(part)
      return true if current.symlink?
    end
    false
  end

  def self.path_inside?(path, root)
    path = Pathname.new(path).expand_path.cleanpath.to_s
    root = Pathname.new(root).expand_path.cleanpath.to_s
    path == root || path.start_with?("#{root}/")
  end

  def self.source_max_bytes
    value = ENV.fetch("STRICT_FDR_SOURCE_MAX_BYTES", DEFAULT_SOURCE_MAX_BYTES.to_s).to_i
    value.positive? ? value : DEFAULT_SOURCE_MAX_BYTES
  end

  def self.normalize_time(value)
    Time.iso8601(value.to_s).utc
  rescue ArgumentError
    raise "review_generated_at must be RFC3339/ISO8601"
  end

  def self.bounded_required_text(value, field)
    text = bounded_text(value, 4096)
    raise "finding #{field} must be non-empty" if text.empty?

    text
  end

  def self.bounded_text(value, limit)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").strip
    return text if text.bytesize <= limit

    out = +""
    text.each_char do |char|
      break if out.bytesize + char.bytesize > limit

      out << char
    end
    out
  end

  def self.digest_json_array(array)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(array))
  end

  def self.sha256?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end
end
