# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "global_ledger_lib"
require_relative "metadata_lib"

class StrictModeTransactionMarker
  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  FIELDS = %w[
    backup_manifest_hash
    created_at
    install_root
    marker_hash
    phase
    previous_active_runtime_path
    previous_install_baseline_hash
    previous_install_manifest_hash
    provider_config_plan_hash
    schema_version
    staged_install_baseline_hash
    staged_install_manifest_hash
    staged_runtime_path
    state_root
    transaction_id
    updated_at
  ].freeze
  HASH_FIELDS = %w[
    backup_manifest_hash
    marker_hash
    previous_install_baseline_hash
    previous_install_manifest_hash
    provider_config_plan_hash
    staged_install_baseline_hash
    staged_install_manifest_hash
  ].freeze
  COMPLETED_PENDING_PHASES = %w[
    activating
    rollback-in-progress
    uninstalling
  ].freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def self.now
    Time.now.utc.iso8601
  end

  def self.json_hash(record, field)
    clone = JSON.parse(JSON.generate(record))
    clone[field] = ""
    StrictModeMetadata.hash_record(clone, field)
  end

  def self.write_json(path, record, hash_field)
    record[hash_field] = json_hash(record, hash_field)
    path.dirname.mkpath
    tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
    tmp.write(JSON.pretty_generate(record) + "\n")
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
  end

  def self.load_json!(path, label = "transaction marker")
    raise "#{path}: #{label} must not be a symlink" if path.symlink?
    raise "#{path}: missing #{label}" unless path.file?

    record = JSON.parse(path.read, object_class: DuplicateKeyHash)
    raise "#{path}: #{label} must be a JSON object" unless record.is_a?(Hash)

    JSON.parse(JSON.generate(record))
  rescue JSON::ParserError, RuntimeError => e
    raise "#{path}: malformed #{label}: #{e.message}"
  end

  def self.verify_hash!(record, field, path)
    expected = json_hash(record, field)
    raise "#{path}: #{field} mismatch" unless record[field] == expected
  end

  def self.require_exact_fields!(record, path)
    actual = record.keys.sort
    expected = FIELDS.sort
    return if actual == expected

    missing = expected - actual
    extra = actual - expected
    details = []
    details << "missing #{missing.join(", ")}" unless missing.empty?
    details << "extra #{extra.join(", ")}" unless extra.empty?
    raise "#{path}: fields mismatch (#{details.join("; ")})"
  end

  def self.require_string!(record, field, path, non_empty: true)
    value = record[field]
    raise "#{path}: #{field} must be a string" unless value.is_a?(String)
    raise "#{path}: #{field} must be non-empty" if non_empty && value.empty?

    value
  end

  def self.require_hash!(record, field, path)
    value = require_string!(record, field, path)
    raise "#{path}: #{field} must be lowercase SHA-256" unless value.match?(SHA256_PATTERN)
  end

  def self.validate_shape!(marker, path)
    raise "#{path}: marker must be an object" unless marker.is_a?(Hash)

    require_exact_fields!(marker, path)
    raise "#{path}: schema_version must be 1" unless marker["schema_version"] == 1

    FIELDS.each do |field|
      next if field == "schema_version"

      require_string!(marker, field, path, non_empty: !%w[staged_runtime_path previous_active_runtime_path].include?(field))
    end
    HASH_FIELDS.each { |field| require_hash!(marker, field, path) }
  end

  def self.validate_complete_for_pending!(complete_marker, pending_marker, complete_path)
    validate_shape!(complete_marker, complete_path)
    raise "#{complete_path}: phase must be complete" unless complete_marker.fetch("phase") == "complete"

    (FIELDS - %w[phase updated_at marker_hash]).each do |field|
      next if complete_marker.fetch(field) == pending_marker.fetch(field)

      raise "#{complete_path}: #{field} mismatch pending marker"
    end
  end

  def self.transaction_writer(transaction_id)
    transaction_id.start_with?("uninstall-") ? "uninstall" : "install"
  end

  def self.pending_marker_writer(marker)
    return "rollback" if marker.fetch("phase") == "rollback-in-progress"

    transaction_writer(marker.fetch("transaction_id"))
  end

  def self.marker_records(state_root, path)
    ledger_path = StrictModeGlobalLedger.ledger_path(state_root)
    StrictModeGlobalLedger.load_records(ledger_path).select do |record|
      record.fetch("target_class") == "installer-marker" &&
        record.fetch("target_path") == path.to_s
    end
  end

  def self.marker_operation_records(state_root, path, operation)
    marker_records(state_root, path).select { |record| record.fetch("operation") == operation }
  end

  def self.complete_marker_create_record!(state_root, complete_path, complete_marker)
    fingerprint = StrictModeGlobalLedger.fingerprint(complete_path)
    records = marker_operation_records(state_root, complete_path, "create")
    valid_records = records.select do |record|
      record.fetch("new_fingerprint") == fingerprint &&
        record.fetch("related_record_hash") == complete_marker.fetch("marker_hash")
    end
    raise "#{complete_path}: complete marker ledger create missing" if records.empty?
    raise "#{complete_path}: duplicate complete marker ledger creates" if records.size > 1 || valid_records.size > 1
    raise "#{complete_path}: complete marker ledger create mismatch" if valid_records.empty?

    valid_records.fetch(0)
  end

  def self.ensure_complete_marker_ledgered!(state_root, writer, complete_path, complete_marker)
    fingerprint = StrictModeGlobalLedger.fingerprint(complete_path)
    records = marker_operation_records(state_root, complete_path, "create")
    valid_records = records.select do |record|
      record.fetch("new_fingerprint") == fingerprint &&
        record.fetch("related_record_hash") == complete_marker.fetch("marker_hash")
    end
    wrong_writer_valid_records = valid_records.reject { |record| record.fetch("writer") == writer }
    unless wrong_writer_valid_records.empty?
      raise "#{complete_path}: complete marker ledger create writer mismatch"
    end
    raise "#{complete_path}: duplicate complete marker ledger creates" if records.size > 1 || valid_records.size > 1
    return if valid_records.size == 1
    raise "#{complete_path}: complete marker ledger create mismatch" unless records.empty?

    StrictModeGlobalLedger.append_change!(
      state_root,
      writer: writer,
      target_path: complete_path,
      target_class: "installer-marker",
      old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
      new_fingerprint: fingerprint,
      related_record_hash: complete_marker.fetch("marker_hash")
    )
  end

  def self.pending_marker_records(state_root, writer, pending_path)
    ledger_path = StrictModeGlobalLedger.ledger_path(state_root)
    StrictModeGlobalLedger.load_records(ledger_path).select do |record|
      record.fetch("writer") == writer &&
        record.fetch("target_class") == "installer-marker" &&
        record.fetch("target_path") == pending_path.to_s
    end
  end

  def self.pending_delete_preimage!(state_root, writer, pending_path)
    records = pending_marker_records(state_root, writer, pending_path)
    record = records.reverse.find do |candidate|
      candidate.fetch("operation") != "delete" &&
        candidate.fetch("new_fingerprint") != StrictModeGlobalLedger.missing_fingerprint
    end
    raise "#{pending_path}: pending marker ledger pre-delete fingerprint missing" unless record

    record.fetch("new_fingerprint")
  end

  def self.latest_pending_marker_writer!(state_root, pending_path)
    record = marker_records(state_root, pending_path).reverse.find do |candidate|
      candidate.fetch("operation") != "delete" &&
        candidate.fetch("new_fingerprint") != StrictModeGlobalLedger.missing_fingerprint
    end
    raise "#{pending_path}: pending marker ledger pre-delete fingerprint missing" unless record

    record.fetch("writer")
  end

  def self.ensure_pending_delete_ledgered!(state_root, writer, pending_path, complete_marker, old_fingerprint: nil)
    old_fingerprint ||= pending_delete_preimage!(state_root, writer, pending_path)
    expected_new = StrictModeGlobalLedger.missing_fingerprint
    raise "#{pending_path}: pending marker delete preimage missing" if old_fingerprint == expected_new

    delete_records = marker_operation_records(state_root, pending_path, "delete")
    valid_records = delete_records.select do |record|
      record.fetch("old_fingerprint") == old_fingerprint &&
        record.fetch("new_fingerprint") == expected_new &&
        record.fetch("related_record_hash") == complete_marker.fetch("marker_hash")
    end
    wrong_writer_valid_records = valid_records.reject { |record| record.fetch("writer") == writer }
    unless wrong_writer_valid_records.empty?
      raise "#{pending_path}: pending marker delete ledger writer mismatch"
    end
    raise "#{pending_path}: duplicate pending marker delete ledger records" if delete_records.size > 1 || valid_records.size > 1
    return if valid_records.size == 1
    raise "#{pending_path}: pending marker delete ledger mismatch" unless delete_records.empty?

    StrictModeGlobalLedger.append_change!(
      state_root,
      writer: writer,
      target_path: pending_path,
      target_class: "installer-marker",
      old_fingerprint: old_fingerprint,
      new_fingerprint: expected_new,
      related_record_hash: complete_marker.fetch("marker_hash")
    )
  end

  def self.install_transaction_dir(install_root)
    Pathname.new(install_root).join("install-transactions")
  end

  def self.pending_paths(install_root)
    Dir[install_transaction_dir(install_root).join("*.pending.json")].sort.map { |path| Pathname.new(path) }
  end

  def self.complete_path_for(pending_path, transaction_id)
    pending_path.dirname.join("#{transaction_id}.complete.json")
  end

  def self.pending_path_for(complete_path, transaction_id)
    complete_path.dirname.join("#{transaction_id}.pending.json")
  end

  def self.validate_pending_binding!(pending_marker, pending_path, install_root, state_root)
    expected_transaction_id = pending_path.basename.to_s.sub(/\.pending\.json\z/, "")
    unless pending_marker.fetch("transaction_id") == expected_transaction_id
      raise "#{pending_path}: transaction_id mismatch filename"
    end
    unless pending_marker.fetch("install_root") == Pathname.new(install_root).to_s
      raise "#{pending_path}: install_root mismatch"
    end
    unless pending_marker.fetch("state_root") == Pathname.new(state_root).to_s
      raise "#{pending_path}: state_root mismatch"
    end
  end

  def self.cleanup_completed_pending_markers!(state_root:, install_root:)
    pending_paths(install_root).each do |pending_path|
      pending_marker = load_json!(pending_path)
      verify_hash!(pending_marker, "marker_hash", pending_path)
      validate_shape!(pending_marker, pending_path)
      validate_pending_binding!(pending_marker, pending_path, install_root, state_root)
      transaction_id = pending_marker.fetch("transaction_id")
      complete_path = complete_path_for(pending_path, transaction_id)
      next unless complete_path.symlink? || complete_path.exist?

      phase = pending_marker.fetch("phase")
      unless COMPLETED_PENDING_PHASES.include?(phase)
        raise "#{pending_path}: phase #{phase.inspect} cannot be completed by pending cleanup"
      end

      complete_marker = load_json!(complete_path)
      verify_hash!(complete_marker, "marker_hash", complete_path)
      validate_complete_for_pending!(complete_marker, pending_marker, complete_path)
      writer = pending_marker_writer(pending_marker)
      ensure_complete_marker_ledgered!(state_root, writer, complete_path, complete_marker)

      delete_pending_marker_after_complete!(state_root, writer, pending_path, complete_marker)
    end
  end

  def self.complete_paths(install_root)
    Dir[install_transaction_dir(install_root).join("*.complete.json")].sort.map { |path| Pathname.new(path) }
  end

  def self.validate_complete_binding!(complete_marker, complete_path, install_root, state_root)
    expected_transaction_id = complete_path.basename.to_s.sub(/\.complete\.json\z/, "")
    unless complete_marker.fetch("transaction_id") == expected_transaction_id
      raise "#{complete_path}: transaction_id mismatch filename"
    end
    raise "#{complete_path}: install_root mismatch" unless complete_marker.fetch("install_root") == Pathname.new(install_root).to_s
    raise "#{complete_path}: state_root mismatch" unless complete_marker.fetch("state_root") == Pathname.new(state_root).to_s
  end

  def self.repair_completed_marker_ledgers!(state_root:, install_root:)
    complete_paths(install_root).each do |complete_path|
      complete_marker = load_json!(complete_path, "complete transaction marker")
      verify_hash!(complete_marker, "marker_hash", complete_path)
      validate_shape!(complete_marker, complete_path)
      raise "#{complete_path}: phase must be complete" unless complete_marker.fetch("phase") == "complete"

      validate_complete_binding!(complete_marker, complete_path, install_root, state_root)
      pending_path = pending_path_for(complete_path, complete_marker.fetch("transaction_id"))
      next if pending_path.symlink? || pending_path.exist?

      create_record = complete_marker_create_record!(state_root, complete_path, complete_marker)
      expected_writer = latest_pending_marker_writer!(state_root, pending_path)
      unless create_record.fetch("writer") == expected_writer
        raise "#{complete_path}: complete marker ledger create writer mismatch"
      end
      ensure_pending_delete_ledgered!(state_root, expected_writer, pending_path, complete_marker)
    end
  end

  def self.assert_no_pending_markers!(install_root)
    paths = pending_paths(install_root)
    return if paths.empty?

    raise "#{install_root}: pending transaction markers require rollback/repair: #{paths.map(&:to_s).join(", ")}"
  end

  def self.publish_complete_marker!(state_root:, writer:, complete_path:, marker:)
    if complete_path.symlink? || complete_path.exist?
      complete_marker = load_json!(complete_path)
      verify_hash!(complete_marker, "marker_hash", complete_path)
      validate_complete_for_pending!(complete_marker, marker, complete_path)
      ensure_complete_marker_ledgered!(state_root, writer, complete_path, complete_marker)
      return complete_marker
    end

    complete_marker = marker.merge(
      "phase" => "complete",
      "updated_at" => now,
      "marker_hash" => ""
    )
    write_json(complete_path, complete_marker, "marker_hash")
    raise "test fault after complete marker write before ledger append" if ENV["STRICT_TEST_FAIL_AFTER_COMPLETE_MARKER_WRITE"] == "1"

    ensure_complete_marker_ledgered!(state_root, writer, complete_path, complete_marker)
    complete_marker
  end

  def self.delete_pending_marker_after_complete!(state_root, writer, pending_path, complete_marker)
    FileUtils.rm_f(pending_path) if ENV["STRICT_TEST_REMOVE_PENDING_BEFORE_PENDING_MARKER_DELETE"] == "1"
    pending_before_delete = StrictModeGlobalLedger.fingerprint(pending_path)
    FileUtils.rm_f(pending_path)
    raise "test fault after pending marker delete before ledger append" if ENV["STRICT_TEST_FAIL_AFTER_PENDING_MARKER_DELETE"] == "1"

    ensure_pending_delete_ledgered!(
      state_root,
      writer,
      pending_path,
      complete_marker,
      old_fingerprint: pending_before_delete
    )
  end
end
