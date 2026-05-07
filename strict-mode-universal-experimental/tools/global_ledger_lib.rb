# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "metadata_lib"

class StrictModeGlobalLedger
  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze

  LEDGER_FIELDS = %w[
    schema_version
    ledger_scope
    writer
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    target_path
    target_class
    operation
    old_fingerprint
    new_fingerprint
    related_record_hash
    ts
    previous_record_hash
    record_hash
  ].freeze

  FINGERPRINT_FIELDS = %w[
    exists
    kind
    dev
    inode
    mode
    size_bytes
    mtime_ns
    content_sha256
    link_target
    tree_hash
  ].freeze

  WRITERS = %w[install rollback uninstall].freeze
  OPERATIONS = %w[create modify append rename delete checkpoint].freeze
  GLOBAL_INSTALL_TARGET_CLASSES = %w[
    installer-marker
    installer-backup
    install-manifest
    install-release
    active-runtime-link
    provider-config
    runtime-config
    protected-config
    protected-install-baseline
  ].freeze

  BACKUP_KIND_TARGET_CLASS = {
    "provider-config" => "provider-config",
    "runtime-config" => "runtime-config",
    "protected-config" => "protected-config",
    "install-manifest" => "install-manifest",
    "install-baseline" => "protected-install-baseline",
    "active-runtime" => "active-runtime-link"
  }.freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def self.ledger_path(state_root)
    Pathname.new(state_root).join("trusted-state-ledger-global.jsonl")
  end

  def self.missing_fingerprint
    {
      "exists" => 0,
      "kind" => "missing",
      "dev" => 0,
      "inode" => 0,
      "mode" => 0,
      "size_bytes" => 0,
      "mtime_ns" => 0,
      "content_sha256" => ZERO_HASH,
      "link_target" => "",
      "tree_hash" => ZERO_HASH
    }
  end

  def self.fingerprint(path)
    path = Pathname.new(path)
    stat = path.lstat
    if stat.symlink?
      link_target = path.readlink.to_s
      return base_fingerprint(stat).merge(
        "kind" => "symlink",
        "content_sha256" => Digest::SHA256.hexdigest(link_target),
        "link_target" => link_target,
        "tree_hash" => ZERO_HASH
      )
    end
    if stat.file?
      return base_fingerprint(stat).merge(
        "kind" => "file",
        "content_sha256" => Digest::SHA256.file(path).hexdigest,
        "link_target" => "",
        "tree_hash" => ZERO_HASH
      )
    end
    if stat.directory?
      return base_fingerprint(stat).merge(
        "kind" => "directory",
        "content_sha256" => ZERO_HASH,
        "link_target" => "",
        "tree_hash" => directory_tree_hash(path)
      )
    end

    missing_fingerprint
  rescue Errno::ENOENT
    missing_fingerprint
  end

  def self.backup_record_fingerprint(record, active_fingerprint = nil)
    return normalize_active_fingerprint(active_fingerprint) if record.fetch("kind") == "active-runtime" && active_fingerprint
    return missing_fingerprint if record.fetch("existed") == 0

    {
      "exists" => 1,
      "kind" => "file",
      "dev" => record.fetch("dev"),
      "inode" => record.fetch("inode"),
      "mode" => record.fetch("mode"),
      "size_bytes" => record.fetch("size_bytes"),
      "mtime_ns" => 0,
      "content_sha256" => record.fetch("content_sha256"),
      "link_target" => "",
      "tree_hash" => ZERO_HASH
    }
  end

  def self.append_backup_changes!(state_root, writer:, backup_manifest:, kinds:, related_record_hash:)
    active_fingerprint = backup_manifest.fetch("previous_active_runtime_fingerprint", nil)
    backup_manifest.fetch("backup_file_records").each do |record|
      next unless kinds.include?(record.fetch("kind"))

      target_class = BACKUP_KIND_TARGET_CLASS.fetch(record.fetch("kind"))
      old_fingerprint = backup_record_fingerprint(record, active_fingerprint)
      append_change!(
        state_root,
        writer: writer,
        target_path: record.fetch("path"),
        target_class: target_class,
        old_fingerprint: old_fingerprint,
        new_fingerprint: fingerprint(record.fetch("path")),
        related_record_hash: related_record_hash
      )
    end
  end

  def self.append_change!(state_root, writer:, target_path:, target_class:, old_fingerprint:, new_fingerprint:, related_record_hash: ZERO_HASH)
    return nil if old_fingerprint == new_fingerprint

    append_global!(
      state_root,
      writer: writer,
      target_path: target_path,
      target_class: target_class,
      operation: operation_for(old_fingerprint, new_fingerprint),
      old_fingerprint: old_fingerprint,
      new_fingerprint: new_fingerprint,
      related_record_hash: related_record_hash
    )
  end

  def self.append_global!(state_root, writer:, target_path:, target_class:, operation:, old_fingerprint:, new_fingerprint:, related_record_hash:)
    path = ledger_path(state_root)
    path.dirname.mkpath
    previous_record_hash = last_record_hash(path)
    record = {
      "schema_version" => 1,
      "ledger_scope" => "global",
      "writer" => writer,
      "provider" => "",
      "session_key" => "",
      "raw_session_hash" => "",
      "cwd" => "",
      "project_dir" => "",
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
    errors = validate_record(record, expected_previous_hash: previous_record_hash)
    raise "global ledger record invalid: #{errors.join("; ")}" unless errors.empty?

    new_file = !path.exist?
    File.open(path.to_s, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
      file.write(JSON.generate(record) + "\n")
    end
    File.chmod(0o600, path) if new_file
    record
  end

  def self.load_records(path)
    path = Pathname.new(path)
    return [] unless path.exist?
    raise "#{path}: ledger must be a file" unless path.file?
    raise "#{path}: ledger must not be a symlink" if path.symlink?

    path.read.lines.each_with_index.map do |line, index|
      text = line.strip
      raise "#{path}: blank ledger line #{index + 1}" if text.empty?

      record = JSON.parse(text, object_class: DuplicateKeyHash)
      raise "#{path}: ledger line #{index + 1} must be an object" unless record.is_a?(Hash)

      JSON.parse(JSON.generate(record))
    end
  end

  def self.validate_chain(path)
    previous = ZERO_HASH
    errors = []
    load_records(path).each_with_index do |record, index|
      record_errors = validate_record(record, expected_previous_hash: previous)
      errors.concat(record_errors.map { |error| "line #{index + 1}: #{error}" })
      previous = record["record_hash"] if record.is_a?(Hash) && record["record_hash"].is_a?(String)
    end
    errors
  rescue JSON::ParserError, RuntimeError => e
    [e.message]
  end

  def self.verify_chain!(state_root)
    path = ledger_path(state_root)
    errors = validate_chain(path)
    raise "#{path}: global ledger chain invalid:\n#{errors.map { |error| "- #{error}" }.join("\n")}" unless errors.empty?

    true
  end

  def self.validate_record(record, expected_previous_hash: nil)
    return ["ledger record must be a JSON object"] unless record.is_a?(Hash)

    errors = []
    actual = record.keys.sort
    expected = LEDGER_FIELDS.sort
    if actual != expected
      missing = expected - actual
      extra = actual - expected
      details = []
      details << "missing #{missing.join(", ")}" unless missing.empty?
      details << "extra #{extra.join(", ")}" unless extra.empty?
      errors << "ledger fields mismatch (#{details.join("; ")})"
      return errors
    end

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "ledger_scope must be global" unless record.fetch("ledger_scope") == "global"
    errors << "writer invalid" unless WRITERS.include?(record.fetch("writer"))
    %w[provider session_key raw_session_hash cwd project_dir].each do |field|
      errors << "#{field} must be empty for global install ledger" unless record.fetch(field) == ""
    end
    errors << "target_path must be a string" unless record.fetch("target_path").is_a?(String)
    errors << "target_class invalid" unless GLOBAL_INSTALL_TARGET_CLASSES.include?(record.fetch("target_class"))
    if record.fetch("target_class") == "active-runtime-link" && record.fetch("target_path").is_a?(String)
      errors << "active-runtime-link target_path must end with /active" unless Pathname.new(record.fetch("target_path")).basename.to_s == "active"
    end
    errors << "operation invalid" unless OPERATIONS.include?(record.fetch("operation"))
    errors << "related_record_hash must be lowercase SHA-256" unless sha256?(record.fetch("related_record_hash"))
    errors << "previous_record_hash must be lowercase SHA-256" unless sha256?(record.fetch("previous_record_hash"))
    errors << "previous_record_hash mismatch" if expected_previous_hash && record.fetch("previous_record_hash") != expected_previous_hash
    errors << "record_hash must be lowercase SHA-256" unless sha256?(record.fetch("record_hash"))
    errors << "record_hash mismatch" if sha256?(record.fetch("record_hash")) &&
      StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
    %w[old_fingerprint new_fingerprint].each do |field|
      errors.concat(validate_fingerprint(record.fetch(field)).map { |error| "#{field}: #{error}" })
    end
    if validate_fingerprint(record.fetch("old_fingerprint")).empty? &&
       validate_fingerprint(record.fetch("new_fingerprint")).empty? &&
       OPERATIONS.include?(record.fetch("operation")) &&
       !operation_matches_fingerprints?(record.fetch("operation"), record.fetch("old_fingerprint"), record.fetch("new_fingerprint"))
      errors << "operation does not match old/new fingerprints"
    end
    errors
  end

  def self.validate_fingerprint(fingerprint)
    return ["fingerprint must be a JSON object"] unless fingerprint.is_a?(Hash)

    errors = []
    actual = fingerprint.keys.sort
    expected = FINGERPRINT_FIELDS.sort
    if actual != expected
      missing = expected - actual
      extra = actual - expected
      details = []
      details << "missing #{missing.join(", ")}" unless missing.empty?
      details << "extra #{extra.join(", ")}" unless extra.empty?
      errors << "fingerprint fields mismatch (#{details.join("; ")})"
      return errors
    end
    exists = fingerprint.fetch("exists")
    kind = fingerprint.fetch("kind")
    errors << "exists must be 0 or 1" unless [0, 1].include?(exists)
    errors << "kind invalid" unless %w[missing file directory symlink].include?(kind)
    %w[dev inode mode size_bytes mtime_ns].each do |field|
      errors << "#{field} must be a non-negative integer" unless fingerprint.fetch(field).is_a?(Integer) && fingerprint.fetch(field) >= 0
    end
    errors << "content_sha256 must be lowercase SHA-256" unless sha256?(fingerprint.fetch("content_sha256"))
    errors << "tree_hash must be lowercase SHA-256" unless sha256?(fingerprint.fetch("tree_hash"))
    errors << "link_target must be a string" unless fingerprint.fetch("link_target").is_a?(String)
    return errors unless errors.empty?

    validate_fingerprint_coupling(fingerprint)
  end

  def self.operation_for(old_fingerprint, new_fingerprint)
    if old_fingerprint.fetch("exists") == 0 && new_fingerprint.fetch("exists") == 1
      "create"
    elsif old_fingerprint.fetch("exists") == 1 && new_fingerprint.fetch("exists") == 0
      "delete"
    else
      "modify"
    end
  end

  def self.operation_matches_fingerprints?(operation, old_fingerprint, new_fingerprint)
    old_exists = old_fingerprint.fetch("exists")
    new_exists = new_fingerprint.fetch("exists")
    case operation
    when "create"
      old_exists == 0 && new_exists == 1
    when "delete"
      old_exists == 1 && new_exists == 0
    when "modify", "rename"
      old_exists == 1 && new_exists == 1
    else
      operation == operation_for(old_fingerprint, new_fingerprint)
    end
  end

  def self.target_class_for_backup_kind(kind)
    BACKUP_KIND_TARGET_CLASS.fetch(kind)
  end

  def self.base_fingerprint(stat)
    {
      "exists" => 1,
      "dev" => stat.dev,
      "inode" => stat.ino,
      "mode" => stat.mode & 0o7777,
      "size_bytes" => stat.size,
      "mtime_ns" => stat.mtime.nsec
    }
  end

  def self.directory_tree_hash(path)
    entries = Dir.glob(path.join("**/*").to_s, File::FNM_DOTMATCH).reject do |entry|
      basename = File.basename(entry)
      basename == "." || basename == ".."
    end.sort.map do |entry|
      entry_path = Pathname.new(entry)
      relative = entry_path.relative_path_from(path).to_s
      fp = fingerprint(entry_path)
      { "path" => relative, "fingerprint" => fp }
    end
    Digest::SHA256.hexdigest(JSON.generate(entries))
  end

  def self.normalize_active_fingerprint(fingerprint)
    return missing_fingerprint unless fingerprint.is_a?(Hash)

    JSON.parse(JSON.generate(fingerprint)).slice(*FINGERPRINT_FIELDS)
  end

  def self.last_record_hash(path)
    previous = ZERO_HASH
    load_records(path).each_with_index do |record, index|
      errors = validate_record(record, expected_previous_hash: previous)
      raise "#{path}: invalid existing ledger line #{index + 1}: #{errors.join("; ")}" unless errors.empty?

      previous = record.fetch("record_hash")
    end
    previous
  end

  def self.validate_fingerprint_coupling(fingerprint)
    case fingerprint.fetch("kind")
    when "missing"
      return [] if fingerprint == missing_fingerprint

      ["missing fingerprint sentinel mismatch"]
    when "file"
      errors = []
      errors << "file fingerprint must have exists=1" unless fingerprint.fetch("exists") == 1
      errors << "file fingerprint link_target must be empty" unless fingerprint.fetch("link_target") == ""
      errors << "file fingerprint tree_hash must be zero" unless fingerprint.fetch("tree_hash") == ZERO_HASH
      errors << "file fingerprint content hash must not be zero" if fingerprint.fetch("content_sha256") == ZERO_HASH
      errors
    when "directory"
      errors = []
      errors << "directory fingerprint must have exists=1" unless fingerprint.fetch("exists") == 1
      errors << "directory fingerprint content hash must be zero" unless fingerprint.fetch("content_sha256") == ZERO_HASH
      errors << "directory fingerprint link_target must be empty" unless fingerprint.fetch("link_target") == ""
      errors
    when "symlink"
      errors = []
      errors << "symlink fingerprint must have exists=1" unless fingerprint.fetch("exists") == 1
      errors << "symlink link_target must be non-empty" if fingerprint.fetch("link_target").empty?
      errors << "symlink tree_hash must be zero" unless fingerprint.fetch("tree_hash") == ZERO_HASH
      expected = Digest::SHA256.hexdigest(fingerprint.fetch("link_target"))
      errors << "symlink content hash must hash link_target" unless fingerprint.fetch("content_sha256") == expected
      errors
    else
      []
    end
  end

  def self.sha256?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end
end
