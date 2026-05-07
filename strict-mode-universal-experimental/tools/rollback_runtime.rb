#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "time"
require_relative "global_ledger_lib"
require_relative "global_lock_lib"
require_relative "metadata_lib"
require_relative "transaction_marker_lib"

ZERO_HASH = "0" * 64
BACKUP_FILE_KINDS = %w[
  active-runtime
  provider-config
  runtime-config
  protected-config
  install-manifest
  install-baseline
].freeze
BACKUP_MANIFEST_FIELDS = %w[
  backup_file_records
  created_at
  install_root
  manifest_hash
  previous_active_runtime_fingerprint
  previous_active_runtime_kind
  previous_active_runtime_path
  previous_install_baseline_hash
  previous_install_manifest_hash
  protected_config_records
  provider_config_records
  runtime_config_records
  schema_version
  state_root
  transaction_id
].freeze
TRANSACTION_MARKER_FIELDS = %w[
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
PENDING_PHASES = %w[
  activating
  post-activation-failed
  rollback-in-progress
  uninstall-failed
  uninstalling
].freeze
ACTIVE_RUNTIME_FINGERPRINT_FIELDS = %w[
  content_sha256
  dev
  exists
  inode
  kind
  link_target
  mode
  mtime_ns
  path
  size_bytes
  tree_hash
].freeze
BACKUP_FILE_RECORD_FIELDS = %w[
  backup_relative_path
  content_sha256
  dev
  existed
  inode
  kind
  mode
  owner_uid
  path
  provider
  size_bytes
].freeze
SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze

class DuplicateKeyHash < Hash
  def []=(key, value)
    raise "duplicate JSON object key: #{key}" if key?(key)

    super
  end
end

def usage_error(message)
  warn "rollback usage error: #{message}"
  exit 2
end

def fail_rollback(message)
  warn "rollback failed: #{message}"
  exit 1
end

def now
  Time.now.utc.iso8601
end

def expand_path(path)
  Pathname.new(File.expand_path(path)).cleanpath
end

def json_hash(record, field)
  clone = JSON.parse(JSON.generate(record))
  clone[field] = ""
  StrictModeMetadata.hash_record(clone, field)
end

def load_json(path)
  fail_rollback("#{path}: missing JSON file") unless path.file?
  fail_rollback("#{path}: JSON file must not be a symlink") if path.symlink?

  record = JSON.parse(path.read, object_class: DuplicateKeyHash)
  fail_rollback("#{path}: JSON root must be an object") unless record.is_a?(Hash)

  JSON.parse(JSON.generate(record))
rescue JSON::ParserError, RuntimeError => e
  fail_rollback("#{path}: malformed JSON: #{e.message}")
end

def verify_hash!(record, field, path)
  expected = json_hash(record, field)
  fail_rollback("#{path}: #{field} mismatch") unless record[field] == expected
end

def require_exact_fields!(record, fields, label)
  fail_rollback("#{label}: must be an object") unless record.is_a?(Hash)

  actual = record.keys.sort
  expected = fields.sort
  return if actual == expected

  missing = expected - actual
  extra = actual - expected
  details = []
  details << "missing #{missing.join(", ")}" unless missing.empty?
  details << "extra #{extra.join(", ")}" unless extra.empty?
  fail_rollback("#{label}: fields mismatch (#{details.join("; ")})")
end

def require_string!(record, field, label, non_empty: true)
  value = record[field]
  fail_rollback("#{label}: #{field} must be a string") unless value.is_a?(String)
  fail_rollback("#{label}: #{field} must be non-empty") if non_empty && value.empty?
  value
end

def require_hash!(record, field, label, zero_allowed: true)
  value = require_string!(record, field, label, non_empty: true)
  fail_rollback("#{label}: #{field} must be lowercase SHA-256") unless value.match?(SHA256_PATTERN)
  fail_rollback("#{label}: #{field} must not be zero hash") if !zero_allowed && value == ZERO_HASH
  value
end

def require_non_negative_integer!(record, field, label)
  value = record[field]
  fail_rollback("#{label}: #{field} must be a non-negative integer") unless value.is_a?(Integer) && value >= 0
  value
end

def require_canonical_absolute_path!(value, label)
  fail_rollback("#{label}: path must be a string") unless value.is_a?(String)

  path = Pathname.new(value).cleanpath
  fail_rollback("#{label}: path must be absolute") unless path.absolute?
  fail_rollback("#{label}: path must be canonical") unless value == path.to_s
  path
rescue ArgumentError
  fail_rollback("#{label}: path is not normalizable")
end

def uninstall_recovery_marker?(marker)
  phase = marker.fetch("phase", "")
  return true if %w[uninstalling uninstall-failed].include?(phase)

  phase == "rollback-in-progress" && marker.fetch("staged_runtime_path", "").empty?
end

def write_json(path, record, hash_field)
  record[hash_field] = json_hash(record, hash_field)
  path.dirname.mkpath
  tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
  tmp.write(JSON.pretty_generate(record) + "\n")
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def validate_backup_manifest!(backup_manifest, backup_path, marker, install_root, state_root)
  require_exact_fields!(backup_manifest, BACKUP_MANIFEST_FIELDS, backup_path)
  fail_rollback("#{backup_path}: schema_version must be 1") unless backup_manifest["schema_version"] == 1
  %w[transaction_id created_at install_root state_root previous_active_runtime_kind previous_install_manifest_hash previous_install_baseline_hash manifest_hash].each do |field|
    require_string!(backup_manifest, field, backup_path)
  end
  require_string!(backup_manifest, "previous_active_runtime_path", backup_path, non_empty: false)
  %w[previous_install_manifest_hash previous_install_baseline_hash manifest_hash].each do |field|
    require_hash!(backup_manifest, field, backup_path)
  end
  fail_rollback("#{backup_path}: transaction_id mismatch") unless backup_manifest.fetch("transaction_id") == marker.fetch("transaction_id")
  fail_rollback("#{backup_path}: install_root mismatch") unless backup_manifest.fetch("install_root") == install_root.to_s
  fail_rollback("#{backup_path}: state_root mismatch") unless backup_manifest.fetch("state_root") == state_root.to_s
  fail_rollback("#{backup_path}: manifest_hash does not match marker") unless backup_manifest.fetch("manifest_hash") == marker.fetch("backup_manifest_hash")
  fail_rollback("#{backup_path}: previous active runtime path mismatch") unless backup_manifest.fetch("previous_active_runtime_path") == marker.fetch("previous_active_runtime_path")
  fail_rollback("#{backup_path}: previous manifest hash mismatch") unless backup_manifest.fetch("previous_install_manifest_hash") == marker.fetch("previous_install_manifest_hash")
  fail_rollback("#{backup_path}: previous baseline hash mismatch") unless backup_manifest.fetch("previous_install_baseline_hash") == marker.fetch("previous_install_baseline_hash")
  validate_active_runtime_fingerprint!(backup_manifest.fetch("previous_active_runtime_fingerprint"), backup_manifest, backup_path)
  validate_backup_record_arrays!(backup_manifest, backup_path)
end

def validate_transaction_marker!(marker, pending_path, install_root, state_root)
  require_exact_fields!(marker, TRANSACTION_MARKER_FIELDS, pending_path)
  fail_rollback("#{pending_path}: schema_version must be 1") unless marker["schema_version"] == 1
  %w[
    transaction_id
    phase
    install_root
    state_root
    staged_runtime_path
    previous_active_runtime_path
    previous_install_manifest_hash
    previous_install_baseline_hash
    backup_manifest_hash
    staged_install_manifest_hash
    staged_install_baseline_hash
    provider_config_plan_hash
    created_at
    updated_at
    marker_hash
  ].each do |field|
    require_string!(marker, field, pending_path, non_empty: !%w[staged_runtime_path previous_active_runtime_path].include?(field))
  end
  fail_rollback("#{pending_path}: install_root mismatch") unless marker.fetch("install_root") == install_root.to_s
  fail_rollback("#{pending_path}: state_root mismatch") unless marker.fetch("state_root") == state_root.to_s
  if marker.fetch("phase") == "pre-activation"
    fail_rollback("#{pending_path}: pre-activation marker requires installer repair, not rollback")
  end
  fail_rollback("#{pending_path}: phase invalid for pending marker") unless PENDING_PHASES.include?(marker.fetch("phase"))
  %w[
    previous_install_manifest_hash
    previous_install_baseline_hash
    backup_manifest_hash
    staged_install_manifest_hash
    staged_install_baseline_hash
    provider_config_plan_hash
    marker_hash
  ].each do |field|
    require_hash!(marker, field, pending_path)
  end
  if uninstall_recovery_marker?(marker)
    fail_rollback("#{pending_path}: uninstall marker staged_runtime_path must be empty") unless marker.fetch("staged_runtime_path").empty?
    fail_rollback("#{pending_path}: uninstall transaction_id must use uninstall- prefix") unless marker.fetch("transaction_id").start_with?("uninstall-")
  else
    staged = require_canonical_absolute_path!(marker.fetch("staged_runtime_path"), "#{pending_path}: staged_runtime_path")
    releases = install_root.join("releases").to_s
    fail_rollback("#{pending_path}: staged_runtime_path must be under install releases") unless staged.to_s.start_with?("#{releases}/")
  end
end

def validate_active_runtime_fingerprint!(fingerprint, backup_manifest, backup_path)
  require_exact_fields!(fingerprint, ACTIVE_RUNTIME_FINGERPRINT_FIELDS, "#{backup_path}: previous_active_runtime_fingerprint")
  kind = fingerprint.fetch("kind")
  fail_rollback("#{backup_path}: previous_active_runtime_kind invalid") unless %w[missing symlink directory].include?(backup_manifest.fetch("previous_active_runtime_kind"))
  fail_rollback("#{backup_path}: previous_active_runtime_fingerprint kind invalid") unless %w[missing symlink directory].include?(kind)
  fail_rollback("#{backup_path}: previous_active_runtime_kind mismatch fingerprint") unless backup_manifest.fetch("previous_active_runtime_kind") == kind
  fail_rollback("#{backup_path}: previous_active_runtime_path mismatch fingerprint") unless backup_manifest.fetch("previous_active_runtime_path") == fingerprint.fetch("path")
  %w[path link_target content_sha256 tree_hash kind].each { |field| require_string!(fingerprint, field, "#{backup_path}: previous_active_runtime_fingerprint", non_empty: false) }
  %w[dev inode mode size_bytes mtime_ns exists].each { |field| require_non_negative_integer!(fingerprint, field, "#{backup_path}: previous_active_runtime_fingerprint") }
  %w[content_sha256 tree_hash].each { |field| require_hash!(fingerprint, field, "#{backup_path}: previous_active_runtime_fingerprint") }
  case kind
  when "missing"
    fail_rollback("#{backup_path}: missing active runtime fingerprint invalid") unless fingerprint.fetch("exists") == 0 &&
      fingerprint.fetch("path") == "" &&
      fingerprint.fetch("link_target") == "" &&
      fingerprint.fetch("dev") == 0 &&
      fingerprint.fetch("inode") == 0 &&
      fingerprint.fetch("mode") == 0 &&
      fingerprint.fetch("size_bytes") == 0 &&
      fingerprint.fetch("mtime_ns") == 0 &&
      fingerprint.fetch("content_sha256") == ZERO_HASH &&
      fingerprint.fetch("tree_hash") == ZERO_HASH
  when "symlink"
    fail_rollback("#{backup_path}: symlink active runtime fingerprint invalid") unless fingerprint.fetch("exists") == 1 &&
      !fingerprint.fetch("path").empty? &&
      !fingerprint.fetch("link_target").empty? &&
      fingerprint.fetch("content_sha256") == Digest::SHA256.hexdigest(fingerprint.fetch("link_target")) &&
      fingerprint.fetch("tree_hash") == ZERO_HASH
    require_canonical_absolute_path!(fingerprint.fetch("path"), "#{backup_path}: previous_active_runtime_fingerprint")
  when "directory"
    fail_rollback("#{backup_path}: directory active runtime fingerprint invalid") unless fingerprint.fetch("exists") == 1 &&
      !fingerprint.fetch("path").empty? &&
      fingerprint.fetch("link_target") == "" &&
      fingerprint.fetch("content_sha256") == ZERO_HASH
    require_canonical_absolute_path!(fingerprint.fetch("path"), "#{backup_path}: previous_active_runtime_fingerprint")
  end
end

def validate_backup_record_arrays!(backup_manifest, backup_path)
  records = backup_manifest.fetch("backup_file_records")
  fail_rollback("#{backup_path}: backup_file_records must be an array") unless records.is_a?(Array)
  seen = {}
  records.each_with_index do |record, index|
    validate_backup_record_shape!(record, "#{backup_path}: backup_file_records #{index}")
    key = [record.fetch("path"), record.fetch("kind"), record.fetch("provider")]
    fail_rollback("#{backup_path}: duplicate backup_file_records path/kind/provider") if seen[key]

    seen[key] = true
  end

  {
    "provider_config_records" => "provider-config",
    "protected_config_records" => "protected-config",
    "runtime_config_records" => "runtime-config"
  }.each do |field, kind|
    value = backup_manifest.fetch(field)
    fail_rollback("#{backup_path}: #{field} must be an array") unless value.is_a?(Array)
    value.each_with_index { |record, index| validate_backup_record_shape!(record, "#{backup_path}: #{field} #{index}") }
    expected = records.select { |record| record.fetch("kind") == kind }.sort_by { |record| [record.fetch("path"), record.fetch("provider")] }
    actual = value.sort_by { |record| [record.fetch("path"), record.fetch("provider")] }
    fail_rollback("#{backup_path}: #{field} mismatch backup_file_records") unless actual == expected
  end
end

def validate_backup_record_shape!(record, label)
  require_exact_fields!(record, BACKUP_FILE_RECORD_FIELDS, label)
  kind = require_string!(record, "kind", label)
  fail_rollback("#{label}: kind invalid") unless BACKUP_FILE_KINDS.include?(kind)
  provider = require_string!(record, "provider", label, non_empty: false)
  if kind == "provider-config"
    fail_rollback("#{label}: provider invalid for provider-config") unless %w[claude codex].include?(provider)
  elsif provider != ""
    fail_rollback("#{label}: provider must be empty for #{kind}")
  end
  require_canonical_absolute_path!(record.fetch("path"), label)
  %w[mode owner_uid dev inode size_bytes].each { |field| require_non_negative_integer!(record, field, label) }
  require_hash!(record, "content_sha256", label)
  relative = require_string!(record, "backup_relative_path", label, non_empty: false)
  existed = record.fetch("existed")
  fail_rollback("#{label}: existed must be 0 or 1") unless [0, 1].include?(existed)
  if existed == 1
    fail_rollback("#{label}: missing backup_relative_path") if relative.empty?
    fail_rollback("#{label}: unsafe backup_relative_path") if relative.start_with?("/") || relative.include?("\n") || relative.include?("\0") || relative.split("/").include?("..")
  else
    fail_rollback("#{label}: missing backup record must not reference backup content") unless relative.empty?
    fail_rollback("#{label}: missing backup record must use zero content hash") unless record.fetch("content_sha256") == ZERO_HASH
    %w[mode owner_uid dev inode size_bytes].each do |field|
      fail_rollback("#{label}: missing backup record #{field} must be 0") unless record.fetch(field) == 0
    end
  end
end

def backup_source_for(backup_dir, record)
  fail_rollback("backup file record must be an object") unless record.is_a?(Hash)
  fail_rollback("backup file record kind #{record.fetch("kind", "").inspect} is invalid") unless BACKUP_FILE_KINDS.include?(record.fetch("kind", ""))

  path = Pathname.new(record.fetch("path"))
  fail_rollback("#{path}: backup record path must be absolute") unless path.absolute?
  if record.fetch("existed") == 1
    relative = record.fetch("backup_relative_path")
    fail_rollback("#{path}: missing backup_relative_path") if relative.empty? || relative.include?("..") || relative.start_with?("/")

    source = backup_dir.join(relative)
    fail_rollback("#{source}: missing backup content") unless source.file?
    fail_rollback("#{source}: backup content must not be a symlink") if source.symlink?
    expected_hash = record.fetch("content_sha256")
    actual_hash = Digest::SHA256.file(source).hexdigest
    fail_rollback("#{source}: backup content_sha256 mismatch for #{path}") unless expected_hash == actual_hash

    [path, source]
  elsif record.fetch("existed") == 0
    fail_rollback("#{path}: missing backup record must not reference backup content") unless record.fetch("backup_relative_path", "").empty?
    fail_rollback("#{path}: missing backup record must use zero content hash") unless record.fetch("content_sha256", ZERO_HASH) == ZERO_HASH

    [path, nil]
  else
    fail_rollback("#{path}: backup record existed must be 0 or 1")
  end
end

def restore_file_record(backup_dir, record)
  path, source = backup_source_for(backup_dir, record)
  if record.fetch("existed") == 1
    fail_rollback("#{path}: rollback target must not be a symlink") if path.symlink?
    fail_rollback("#{path}: rollback target must be a file or missing") if path.exist? && !path.file?

    path.dirname.mkpath
    FileUtils.cp(source, path)
    File.chmod(record.fetch("mode") & 0o7777, path) if record.fetch("mode").is_a?(Integer) && record.fetch("mode").positive?
  else
    if path.symlink? || path.file?
      FileUtils.rm_f(path)
    elsif path.exist?
      fail_rollback("#{path}: refuses to remove non-file rollback target")
    end
  end
end

def assert_current_active_symlink!(active, allowed_targets)
  return unless active.symlink?

  target = active.readlink.to_s
  return if allowed_targets.include?(target)

  fail_rollback("#{active}: current active symlink does not match rollback transaction")
end

def validate_current_active_runtime!(install_root, backup_dir, backup_manifest, marker)
  active = install_root.join("active")
  kind = backup_manifest.fetch("previous_active_runtime_kind")
  staged_target = marker.fetch("staged_runtime_path")
  active_record = backup_manifest.fetch("backup_file_records").find { |record| record.fetch("kind") == "active-runtime" }
  case kind
  when "missing"
    if active.symlink?
      assert_current_active_symlink!(active, [staged_target])
    elsif active.exist?
      fail_rollback("#{active}: refuses to remove non-symlink active runtime")
    end
  when "symlink"
    fail_rollback("#{active}: current active runtime is not rollback-safe") if active.exist? && !active.symlink?
    fail_rollback("#{active}: missing active-runtime backup record") unless active_record

    _path, source = backup_source_for(backup_dir, active_record)
    assert_current_active_symlink!(active, [staged_target, source.read].reject(&:empty?))
  else
    fail_rollback("previous active runtime kind #{kind.inspect} is not supported by the discovery rollback skeleton")
  end
end

def restore_active_runtime(install_root, backup_dir, backup_manifest, marker)
  active = install_root.join("active")
  kind = backup_manifest.fetch("previous_active_runtime_kind")
  staged_target = marker.fetch("staged_runtime_path")
  active_record = backup_manifest.fetch("backup_file_records").find { |record| record.fetch("kind") == "active-runtime" }
  case kind
  when "missing"
    if active.symlink?
      assert_current_active_symlink!(active, [staged_target])
      FileUtils.rm_f(active)
    elsif active.exist?
      fail_rollback("#{active}: refuses to remove non-symlink active runtime")
    end
  when "symlink"
    fail_rollback("#{active}: current active runtime is not rollback-safe") if active.exist? && !active.symlink?
    fail_rollback("#{active}: missing active-runtime backup record") unless active_record

    _path, source = backup_source_for(backup_dir, active_record)
    target = source.read
    assert_current_active_symlink!(active, [staged_target, target].reject(&:empty?))
    tmp = install_root.join(".active.rollback-#{$$}-#{SecureRandom.hex(4)}")
    FileUtils.rm_f(tmp)
    File.symlink(target, tmp)
    File.rename(tmp, active)
  else
    fail_rollback("previous active runtime kind #{kind.inspect} is not supported by the discovery rollback skeleton")
  end
end

def restore_record_order(record)
  {
    "runtime-config" => 0,
    "protected-config" => 1,
    "install-manifest" => 2,
    "install-baseline" => 3
  }.fetch(record.fetch("kind"), 99)
end

def validate_backup_sources!(backup_dir, backup_manifest)
  records = backup_manifest.fetch("backup_file_records")
  fail_rollback("backup_file_records must be an array") unless records.is_a?(Array)

  records.each { |record| backup_source_for(backup_dir, record) }
end

def validate_restored_file_record!(record)
  path = Pathname.new(record.fetch("path"))
  if record.fetch("existed") == 1
    fail_rollback("#{path}: post-restore target must not be a symlink") if path.symlink?
    fail_rollback("#{path}: post-restore target must be a file") unless path.file?
    actual_hash = Digest::SHA256.file(path).hexdigest
    fail_rollback("#{path}: post-restore content_sha256 mismatch") unless actual_hash == record.fetch("content_sha256")
    fail_rollback("#{path}: post-restore size mismatch") unless path.size == record.fetch("size_bytes")
    actual_mode = path.stat.mode & 0o7777
    expected_mode = record.fetch("mode") & 0o7777
    fail_rollback("#{path}: post-restore mode mismatch") unless actual_mode == expected_mode
  else
    fail_rollback("#{path}: post-restore missing target is a symlink") if path.symlink?
    fail_rollback("#{path}: post-restore target should be missing") if path.exist?
  end
end

def validate_restored_active_runtime!(install_root, backup_manifest)
  active = install_root.join("active")
  fingerprint = backup_manifest.fetch("previous_active_runtime_fingerprint")
  case backup_manifest.fetch("previous_active_runtime_kind")
  when "missing"
    fail_rollback("#{active}: post-restore active runtime should be missing") if active.symlink? || active.exist?
  when "symlink"
    fail_rollback("#{active}: post-restore active runtime must be a symlink") unless active.symlink?

    target = active.readlink.to_s
    fail_rollback("#{active}: post-restore active symlink target mismatch") unless target == fingerprint.fetch("link_target")
    actual_hash = Digest::SHA256.hexdigest(target)
    fail_rollback("#{active}: post-restore active symlink hash mismatch") unless actual_hash == fingerprint.fetch("content_sha256")
  else
    fail_rollback("previous active runtime kind #{backup_manifest.fetch("previous_active_runtime_kind").inspect} is not supported by the discovery rollback skeleton")
  end
end

def validate_restored_state!(install_root, backup_manifest, marker)
  backup_manifest.fetch("backup_file_records").each do |record|
    if record.fetch("kind") == "active-runtime"
      validate_restored_active_runtime!(install_root, backup_manifest)
    else
      validate_restored_file_record!(record)
    end
  end
  staged = marker.fetch("staged_runtime_path")
  return if staged.empty?

  staged_path = Pathname.new(staged)
  fail_rollback("#{staged_path}: staged runtime still exists after rollback") if staged_path.symlink? || staged_path.exist?
end

def tamper_restored_state_after_restore_for_test!(backup_manifest)
  record = backup_manifest.fetch("backup_file_records").find do |candidate|
    candidate.fetch("kind") == "provider-config" && candidate.fetch("existed") == 1
  end
  return unless record

  Pathname.new(record.fetch("path")).write("{\"hooks\":{}}\n")
end

def safe_remove_staged_runtime(install_root, marker)
  staged = marker.fetch("staged_runtime_path")
  return if staged.empty?

  path = Pathname.new(staged)
  releases = install_root.join("releases").to_s
  unless path.to_s.start_with?("#{releases}/")
    fail_rollback("#{path}: staged runtime path is outside install releases")
  end
  FileUtils.rm_rf(path) if path.directory? || path.symlink?
end

def pending_marker_paths(install_root, transaction_id)
  dir = install_root.join("install-transactions")
  return [dir.join("#{transaction_id}.pending.json")] if transaction_id

  Dir[dir.join("*.pending.json")].sort.map { |path| Pathname.new(path) }
end

options = {
  install_root: ENV["STRICT_INSTALL_ROOT"],
  state_root: ENV["STRICT_STATE_ROOT"],
  transaction_id: nil
}

OptionParser.new do |opts|
  opts.on("--install-root PATH") { |value| options[:install_root] = value }
  opts.on("--state-root PATH") { |value| options[:state_root] = value }
  opts.on("--transaction-id ID") { |value| options[:transaction_id] = value }
end.parse!(ARGV)
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

lock = nil

begin
  home = expand_path(ENV.fetch("HOME"))
  install_root = expand_path(options[:install_root] || home.join(".strict-mode"))
  state_root = expand_path(options[:state_root] || install_root.join("state"))
  lock = StrictModeGlobalLock.acquire!(install_root, state_root: state_root, transaction_kind: "rollback")
  StrictModeGlobalLedger.verify_chain!(state_root)
  StrictModeTransactionMarker.repair_completed_marker_ledgers!(state_root: state_root, install_root: install_root)
  marker_paths = pending_marker_paths(install_root, options[:transaction_id])
  fail_rollback("#{install_root}: no pending transaction markers") if marker_paths.empty?
  fail_rollback("#{install_root}: multiple pending transaction markers; pass --transaction-id") if marker_paths.size > 1

  pending_path = marker_paths.fetch(0)
  marker = load_json(pending_path)
  verify_hash!(marker, "marker_hash", pending_path)
  validate_transaction_marker!(marker, pending_path, install_root, state_root)

  backup_path = install_root.join("install-backups/#{marker.fetch("transaction_id")}/backup-manifest.json")
  backup_manifest = load_json(backup_path)
  verify_hash!(backup_manifest, "manifest_hash", backup_path)
  validate_backup_manifest!(backup_manifest, backup_path, marker, install_root, state_root)
  backup_dir = backup_path.dirname
  validate_backup_sources!(backup_dir, backup_manifest)
  validate_current_active_runtime!(install_root, backup_dir, backup_manifest, marker)
  records = backup_manifest.fetch("backup_file_records")
  restore_old_fingerprints = records.each_with_object({}) do |record, index|
    index[record.fetch("path")] = StrictModeGlobalLedger.fingerprint(record.fetch("path"))
  end
  active_old_fingerprint = StrictModeGlobalLedger.fingerprint(install_root.join("active"))
  staged_old_fingerprint = marker.fetch("staged_runtime_path").empty? ? nil : StrictModeGlobalLedger.fingerprint(marker.fetch("staged_runtime_path"))

  rollback_marker = marker.merge(
    "phase" => "rollback-in-progress",
    "updated_at" => now,
    "marker_hash" => ""
  )
  pending_before_phase = StrictModeGlobalLedger.fingerprint(pending_path)
  write_json(pending_path, rollback_marker, "marker_hash")
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "rollback",
    target_path: pending_path,
    target_class: "installer-marker",
    old_fingerprint: pending_before_phase,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(pending_path),
    related_record_hash: rollback_marker.fetch("marker_hash")
  )

  records.select { |record| record.fetch("kind") == "provider-config" }.sort_by { |record| [record.fetch("provider"), record.fetch("path")] }.each do |record|
    restore_file_record(backup_dir, record)
  end
  restore_active_runtime(install_root, backup_dir, backup_manifest, rollback_marker)
  records.reject { |record| %w[active-runtime provider-config].include?(record.fetch("kind")) }.sort_by { |record| [restore_record_order(record), record.fetch("path")] }.each do |record|
    restore_file_record(backup_dir, record)
  end
  safe_remove_staged_runtime(install_root, rollback_marker)
  records.each do |record|
    old_fingerprint = record.fetch("kind") == "active-runtime" ? active_old_fingerprint : restore_old_fingerprints.fetch(record.fetch("path"))
    StrictModeGlobalLedger.append_change!(
      state_root,
      writer: "rollback",
      target_path: record.fetch("path"),
      target_class: StrictModeGlobalLedger.target_class_for_backup_kind(record.fetch("kind")),
      old_fingerprint: old_fingerprint,
      new_fingerprint: StrictModeGlobalLedger.fingerprint(record.fetch("path")),
      related_record_hash: rollback_marker.fetch("marker_hash")
    )
  end
  unless marker.fetch("staged_runtime_path").empty?
    StrictModeGlobalLedger.append_change!(
      state_root,
      writer: "rollback",
      target_path: marker.fetch("staged_runtime_path"),
      target_class: "install-release",
      old_fingerprint: staged_old_fingerprint || StrictModeGlobalLedger.missing_fingerprint,
      new_fingerprint: StrictModeGlobalLedger.fingerprint(marker.fetch("staged_runtime_path")),
      related_record_hash: rollback_marker.fetch("marker_hash")
    )
  end
  tamper_restored_state_after_restore_for_test!(backup_manifest) if ENV["STRICT_TEST_TAMPER_AFTER_RESTORE"] == "1"
  validate_restored_state!(install_root, backup_manifest, rollback_marker)

  complete_path = pending_path.dirname.join("#{marker.fetch("transaction_id")}.complete.json")
  complete_marker = StrictModeTransactionMarker.publish_complete_marker!(
    state_root: state_root,
    writer: "rollback",
    complete_path: complete_path,
    marker: rollback_marker
  )
  raise "test fault after rollback complete marker publication" if ENV["STRICT_TEST_FAIL_AFTER_ROLLBACK_COMPLETE_MARKER"] == "1"

  StrictModeTransactionMarker.delete_pending_marker_after_complete!(state_root, "rollback", pending_path, complete_marker)
  puts "rolled back strict-mode transaction #{marker.fetch("transaction_id")}"
rescue SystemCallError, RuntimeError, JSON::ParserError => e
  fail_rollback(e.message)
ensure
  lock.release if lock
end
