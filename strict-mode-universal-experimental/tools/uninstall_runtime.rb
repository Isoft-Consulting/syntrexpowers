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
require_relative "hook_entry_plan_lib"
require_relative "metadata_lib"
require_relative "protected_baseline_lib"
require_relative "provider_config_fingerprint_lib"
require_relative "transaction_marker_lib"

ZERO_HASH = "0" * 64

class DuplicateKeyHash < Hash
  def []=(key, value)
    raise "duplicate JSON object key: #{key}" if key?(key)

    super
  end
end

def usage_error(message)
  warn "uninstall usage error: #{message}"
  exit 2
end

def fail_uninstall(message)
  warn "uninstall failed: #{message}"
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

def sha256_file(path)
  return ZERO_HASH unless path.file?

  Digest::SHA256.file(path).hexdigest
end

def file_record(path, kind, provider = "")
  exists = path.file? ? 1 : 0
  stat = exists == 1 ? path.stat : nil
  {
    "path" => path.to_s,
    "realpath" => stat ? path.realpath.to_s : "",
    "kind" => kind,
    "provider" => provider,
    "exists" => exists,
    "mode" => stat ? (stat.mode & 0o7777) : 0,
    "owner_uid" => stat ? stat.uid : 0,
    "dev" => stat ? stat.dev : 0,
    "inode" => stat ? stat.ino : 0,
    "size_bytes" => stat ? stat.size : 0,
    "content_sha256" => StrictModeProviderConfigFingerprint.content_sha256(path, kind, provider)
  }
end

def sort_file_records(records)
  records.sort_by { |record| [record.fetch("path"), record.fetch("kind")] }
end

def protected_file_inode_index(records)
  index = {}
  records.flatten.each do |record|
    next unless record.fetch("exists", 0) == 1
    next if StrictModeProviderConfigFingerprint.mutable_provider_state_record?(record.fetch("path"), record.fetch("kind"), record.fetch("provider", ""))

    dev = record.fetch("dev", 0)
    inode = record.fetch("inode", 0)
    next if dev.to_i.zero? || inode.to_i.zero?

    key = "#{dev}:#{inode}"
    index[key] ||= []
    index[key] << {
      "dev" => dev,
      "inode" => inode,
      "path" => record.fetch("path"),
      "kind" => record.fetch("kind"),
      "provider" => record.fetch("provider", ""),
      "content_sha256" => record.fetch("content_sha256")
    }
  end
  index.keys.sort.each_with_object({}) do |key, sorted|
    sorted[key] = index.fetch(key).uniq.sort_by { |entry| [entry.fetch("path"), entry.fetch("kind"), entry.fetch("provider")] }
  end
end

def lstat_or_nil(path)
  path.lstat
rescue Errno::ENOENT
  nil
end

def metadata_for_backup(path, kind, backup_relative_path = "", provider = "")
  stat = lstat_or_nil(path)
  exists = stat ? 1 : 0
  content_sha256 = if stat&.file?
                     sha256_file(path)
                   elsif stat&.symlink?
                     Digest::SHA256.hexdigest(path.readlink.to_s)
                   else
                     ZERO_HASH
                   end
  {
    "path" => path.to_s,
    "kind" => kind,
    "provider" => provider,
    "existed" => exists,
    "mode" => stat ? (stat.mode & 0o7777) : 0,
    "owner_uid" => stat ? stat.uid : 0,
    "dev" => stat ? stat.dev : 0,
    "inode" => stat ? stat.ino : 0,
    "size_bytes" => stat ? stat.size : 0,
    "content_sha256" => content_sha256,
    "backup_relative_path" => exists == 1 ? backup_relative_path : ""
  }
end

def copy_backup_subject(path, backup_dir, relative_path)
  stat = lstat_or_nil(path)
  return unless stat&.file? || stat&.symlink?

  target = backup_dir.join(relative_path)
  target.dirname.mkpath
  if stat.symlink?
    target.write(path.readlink.to_s)
  else
    FileUtils.cp(path, target)
  end
  File.chmod(0o600, target)
end

def active_runtime_fingerprint(active)
  stat = lstat_or_nil(active)
  unless stat
    return {
      "exists" => 0,
      "kind" => "missing",
      "path" => "",
      "link_target" => "",
      "dev" => 0,
      "inode" => 0,
      "mode" => 0,
      "size_bytes" => 0,
      "mtime_ns" => 0,
      "content_sha256" => ZERO_HASH,
      "tree_hash" => ZERO_HASH
    }
  end

  if stat.symlink?
    link_target = active.readlink.to_s
    kind = "symlink"
    content_sha256 = Digest::SHA256.hexdigest(link_target)
  elsif stat.directory?
    link_target = ""
    kind = "directory"
    content_sha256 = ZERO_HASH
  else
    link_target = ""
    kind = "missing"
    content_sha256 = ZERO_HASH
  end
  {
    "exists" => 1,
    "kind" => kind,
    "path" => active.to_s,
    "link_target" => link_target,
    "dev" => stat.dev,
    "inode" => stat.ino,
    "mode" => stat.mode & 0o7777,
    "size_bytes" => stat.size,
    "mtime_ns" => stat.mtime.nsec,
    "content_sha256" => content_sha256,
    "tree_hash" => ZERO_HASH
  }
end

def create_backup_manifest(install_root, state_root, manifest, manifest_path, baseline_path, transaction_id, created_at)
  backup_dir = install_root.join("install-backups/#{transaction_id}")
  backup_dir.mkpath
  active = install_root.join("active")
  active_fingerprint = active_runtime_fingerprint(active)
  records = []
  provider_records = []
  protected_records = []
  runtime_records = []
  subjects = []
  manifest.fetch("provider_config_records").each { |record| subjects << [Pathname.new(record.fetch("path")), "provider-config", record.fetch("provider", "")] }
  manifest.fetch("runtime_config_records").each { |record| subjects << [Pathname.new(record.fetch("path")), "runtime-config", ""] }
  manifest.fetch("protected_config_records").each { |record| subjects << [Pathname.new(record.fetch("path")), "protected-config", ""] }
  subjects << [manifest_path, "install-manifest", ""]
  subjects << [baseline_path, "install-baseline", ""]
  subjects.each do |path, kind, provider|
    relative = "files/#{Digest::SHA256.hexdigest(path.to_s)}"
    copy_backup_subject(path, backup_dir, relative)
    record = metadata_for_backup(path, kind, lstat_or_nil(path) ? relative : "", provider)
    records << record
    provider_records << record if kind == "provider-config"
    protected_records << record if kind == "protected-config"
    runtime_records << record if kind == "runtime-config"
  end
  if active_fingerprint.fetch("exists") == 1 && active_fingerprint.fetch("kind") == "symlink"
    relative = "files/active-runtime-link"
    backup_dir.join(relative).dirname.mkpath
    backup_dir.join(relative).write(active_fingerprint.fetch("link_target"))
    File.chmod(0o600, backup_dir.join(relative))
    records << metadata_for_backup(active, "active-runtime", relative)
  else
    records << metadata_for_backup(active, "active-runtime")
  end

  backup_manifest = {
    "schema_version" => 1,
    "transaction_id" => transaction_id,
    "created_at" => created_at,
    "install_root" => install_root.to_s,
    "state_root" => state_root.to_s,
    "previous_active_runtime_path" => active_fingerprint.fetch("path"),
    "previous_active_runtime_kind" => active_fingerprint.fetch("kind"),
    "previous_active_runtime_fingerprint" => active_fingerprint,
    "previous_install_manifest_hash" => Digest::SHA256.file(manifest_path).hexdigest,
    "previous_install_baseline_hash" => baseline_path.file? ? Digest::SHA256.file(baseline_path).hexdigest : ZERO_HASH,
    "provider_config_records" => provider_records,
    "protected_config_records" => protected_records,
    "runtime_config_records" => runtime_records,
    "backup_file_records" => records,
    "manifest_hash" => ""
  }
  write_json(backup_dir.join("backup-manifest.json"), backup_manifest, "manifest_hash")
  backup_manifest
end

def verify_hash!(record, field, path)
  expected = json_hash(record, field)
  fail_uninstall("#{path}: #{field} mismatch") unless record[field] == expected
end

def write_json(path, record, hash_field)
  record[hash_field] = json_hash(record, hash_field)
  path.dirname.mkpath
  tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
  tmp.write(JSON.pretty_generate(record) + "\n")
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def load_json(path)
  fail_uninstall("#{path}: missing JSON file") unless path.file?
  fail_uninstall("#{path}: JSON file must not be a symlink") if path.symlink?

  record = JSON.parse(path.read, object_class: DuplicateKeyHash)
  fail_uninstall("#{path}: JSON root must be an object") unless record.is_a?(Hash)

  JSON.parse(JSON.generate(record))
rescue JSON::ParserError, RuntimeError => e
  fail_uninstall("#{path}: malformed JSON: #{e.message}")
end

def array_field!(record, field, context)
  value = record[field]
  fail_uninstall("#{context}: #{field} must be an array") unless value.is_a?(Array)

  value
end

def enforcing_hook_plan?(entries, selected_output_contracts)
  !selected_output_contracts.empty? ||
    entries.any? do |entry|
      entry.is_a?(Hash) && (entry["enforcing"] == true || entry["output_contract_id"] != "")
    end
end

def validate_hook_entry_plan!(entries, selected_output_contracts, context, install_root, state_root)
  errors = StrictModeHookEntryPlan.validate(
    entries,
    selected_output_contracts: selected_output_contracts,
    enforce: enforcing_hook_plan?(entries, selected_output_contracts),
    install_root: install_root,
    state_root: state_root
  )
  return if errors.empty?

  fail_uninstall("#{context}: managed hook entry plan invalid:\n#{errors.map { |error| "- #{error}" }.join("\n")}")
end

def write_provider_json(path, record)
  fail_uninstall("#{path}: provider config must not be a symlink") if path.symlink?

  path.dirname.mkpath
  tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
  tmp.write(JSON.pretty_generate(record) + "\n")
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def remove_commands_from_config(path, selectors)
  return unless path.file?

  root = load_json(path)
  hooks = root["hooks"]
  return unless hooks.is_a?(Hash)

  selectors_by_event = selectors.group_by { |selector| selector.fetch("hook_event") }
  hooks.each do |event, entries|
    next unless entries.is_a?(Array)

    event_selectors = selectors_by_event.fetch(event, [])
    entries.reject! do |entry|
      hook_list = entry.is_a?(Hash) ? entry["hooks"] : nil
      next false unless hook_list.is_a?(Array)

      hook_list.reject! { |hook| hook.is_a?(Hash) && event_selectors.any? { |selector| provider_hook_matches_selector?(entry, hook, selector) } }
      hook_list.empty?
    end
  end
  write_provider_json(path, root)
end

def provider_hook_matches_selector?(entry, hook, selector)
  return false unless hook["type"] == "command"
  return false unless hook["command"] == selector.fetch("command")

  entry_matcher = entry["matcher"].is_a?(String) ? entry["matcher"] : ""
  return false unless entry_matcher == selector.fetch("matcher")

  case selector.fetch("provider_timeout_field")
  when "timeout"
    hook["timeout"] == selector.fetch("provider_timeout_ms")
  when ""
    !hook.key?("timeout")
  else
    false
  end
end

def mark_uninstall_failed!(state_root, pending_path)
  return unless state_root && pending_path && pending_path.file?

  current = load_json(pending_path)
  return if current.fetch("phase", "") == "complete"
  return if current.fetch("phase", "") == "uninstall-failed"
  return unless current.fetch("staged_runtime_path", "") == ""

  old_fingerprint = StrictModeGlobalLedger.fingerprint(pending_path)
  failed_marker = current.merge(
    "phase" => "uninstall-failed",
    "updated_at" => now,
    "marker_hash" => ""
  )
  write_json(pending_path, failed_marker, "marker_hash")
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "uninstall",
    target_path: pending_path,
    target_class: "installer-marker",
    old_fingerprint: old_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(pending_path),
    related_record_hash: failed_marker.fetch("marker_hash")
  )
end

def provider_list(value)
  case value
  when "claude", "codex"
    [value]
  when "all", "auto"
    %w[claude codex]
  else
    usage_error("--provider must be claude, codex, all, or auto")
  end
end

options = {
  provider: "auto",
  install_root: ENV["STRICT_INSTALL_ROOT"],
  state_root: ENV["STRICT_STATE_ROOT"]
}

OptionParser.new do |opts|
  opts.on("--provider PROVIDER") { |value| options[:provider] = value }
  opts.on("--install-root PATH") { |value| options[:install_root] = value }
  opts.on("--state-root PATH") { |value| options[:state_root] = value }
end.parse!(ARGV)
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

lock = nil
state_root = nil
pending_path = nil
completion_started = false

begin
home = expand_path(ENV.fetch("HOME"))
install_root = expand_path(options[:install_root] || home.join(".strict-mode"))
state_root = expand_path(options[:state_root] || install_root.join("state"))
providers = provider_list(options[:provider])
lock = StrictModeGlobalLock.acquire!(install_root, state_root: state_root, transaction_kind: "uninstall")
StrictModeGlobalLedger.verify_chain!(state_root)
StrictModeTransactionMarker.cleanup_completed_pending_markers!(state_root: state_root, install_root: install_root)
StrictModeTransactionMarker.repair_completed_marker_ledgers!(state_root: state_root, install_root: install_root)
StrictModeTransactionMarker.assert_no_pending_markers!(install_root)
manifest_path = install_root.join("install-manifest.json")
protected_install = StrictModeProtectedBaseline.load(install_root: install_root, state_root: state_root, home: home)
unless protected_install.fetch("trusted")
  fail_uninstall("protected install baseline untrusted:\n#{protected_install.fetch("errors").map { |error| "- #{error}" }.join("\n")}")
end
manifest = load_json(manifest_path)
verify_hash!(manifest, "manifest_hash", manifest_path)
fail_uninstall("#{manifest_path}: install_root mismatch") unless manifest["install_root"] == install_root.to_s
manifest_entries = array_field!(manifest, "managed_hook_entries", manifest_path)
manifest_output_contracts = array_field!(manifest, "selected_output_contracts", manifest_path)
validate_hook_entry_plan!(manifest_entries, manifest_output_contracts, manifest_path, install_root, state_root)

selected_entries = manifest_entries.select { |entry| providers.include?(entry.fetch("provider")) }
selectors_by_path = selected_entries.map { |entry| entry.fetch("removal_selector") }.group_by { |selector| selector.fetch("config_path") }
remaining_entries = manifest_entries - selected_entries
remaining_output_contracts = manifest_output_contracts.reject { |record| record.is_a?(Hash) && providers.include?(record["provider"]) }
validate_hook_entry_plan!(remaining_entries, remaining_output_contracts, "#{manifest_path} post-uninstall plan", install_root, state_root)
previous_manifest_hash = Digest::SHA256.file(manifest_path).hexdigest
baseline_path = state_root.join("protected-install-baseline.json")
previous_baseline_hash = baseline_path.file? ? Digest::SHA256.file(baseline_path).hexdigest : ZERO_HASH
baseline = nil
if baseline_path.file?
  baseline = load_json(baseline_path)
  verify_hash!(baseline, "baseline_hash", baseline_path)
  baseline_entries = array_field!(baseline, "managed_hook_entries", baseline_path)
  baseline_output_contracts = array_field!(baseline, "selected_output_contracts", baseline_path)
  validate_hook_entry_plan!(baseline_entries, baseline_output_contracts, baseline_path, install_root, state_root)
  fail_uninstall("#{baseline_path}: managed_hook_entries mismatch install manifest") unless baseline_entries == manifest_entries
  fail_uninstall("#{baseline_path}: selected_output_contracts mismatch install manifest") unless baseline_output_contracts == manifest_output_contracts
end
updated_at = now
transaction_id = "uninstall-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{$$}-#{SecureRandom.hex(4)}"
backup_manifest = create_backup_manifest(install_root, state_root, manifest, manifest_path, baseline_path, transaction_id, updated_at)

updated_manifest = JSON.parse(JSON.generate(manifest))
updated_manifest["managed_hook_entries"] = remaining_entries
remaining_providers = remaining_entries.map { |entry| entry.fetch("provider") }.uniq.sort
updated_manifest["fixture_manifest_records"] = manifest.fetch("fixture_manifest_records", []).select { |record| record.is_a?(Hash) && remaining_providers.include?(record["provider"]) }
updated_manifest["selected_output_contracts"] = remaining_output_contracts if updated_manifest.key?("selected_output_contracts")
updated_manifest["updated_at"] = updated_at
updated_manifest["manifest_hash"] = ZERO_HASH

updated_baseline = nil
if baseline
  updated_baseline = JSON.parse(JSON.generate(baseline))
  updated_baseline["managed_hook_entries"] = remaining_entries
  updated_baseline["fixture_manifest_records"] = baseline.fetch("fixture_manifest_records", []).select { |record| record.is_a?(Hash) && remaining_providers.include?(record["provider"]) }
  updated_baseline["selected_output_contracts"] = remaining_output_contracts if updated_baseline.key?("selected_output_contracts")
  updated_baseline["generated_hook_commands"] = remaining_entries.map { |entry| entry.slice("provider", "hook_event", "logical_event", "command") }
  updated_baseline["install_manifest_hash"] = ZERO_HASH
  updated_baseline["updated_at"] = updated_at
  updated_baseline["baseline_hash"] = ZERO_HASH
end

marker = {
  "schema_version" => 1,
  "transaction_id" => transaction_id,
  "phase" => "uninstalling",
  "install_root" => install_root.to_s,
  "state_root" => state_root.to_s,
  "staged_runtime_path" => "",
  "previous_active_runtime_path" => backup_manifest.fetch("previous_active_runtime_path"),
  "previous_install_manifest_hash" => previous_manifest_hash,
  "previous_install_baseline_hash" => previous_baseline_hash,
  "backup_manifest_hash" => backup_manifest.fetch("manifest_hash"),
  "staged_install_manifest_hash" => ZERO_HASH,
  "staged_install_baseline_hash" => ZERO_HASH,
  "provider_config_plan_hash" => ZERO_HASH,
  "created_at" => updated_at,
  "updated_at" => updated_at,
  "marker_hash" => ""
}
marker_dir = install_root.join("install-transactions")
pending_path = marker_dir.join("#{transaction_id}.pending.json")
complete_path = marker_dir.join("#{transaction_id}.complete.json")
write_json(pending_path, marker, "marker_hash")
backup_manifest_path = install_root.join("install-backups/#{transaction_id}/backup-manifest.json")
StrictModeGlobalLedger.append_change!(
  state_root,
  writer: "uninstall",
  target_path: backup_manifest_path,
  target_class: "installer-backup",
  old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
  new_fingerprint: StrictModeGlobalLedger.fingerprint(backup_manifest_path),
  related_record_hash: backup_manifest.fetch("manifest_hash")
)
StrictModeGlobalLedger.append_change!(
  state_root,
  writer: "uninstall",
  target_path: pending_path,
  target_class: "installer-marker",
  old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
  new_fingerprint: StrictModeGlobalLedger.fingerprint(pending_path),
  related_record_hash: marker.fetch("marker_hash")
)
selectors_by_path.each do |path, selectors|
  remove_commands_from_config(Pathname.new(path), selectors)
end
StrictModeGlobalLedger.append_backup_changes!(
  state_root,
  writer: "uninstall",
  backup_manifest: backup_manifest,
  kinds: %w[provider-config],
  related_record_hash: marker.fetch("marker_hash")
)
raise "test fault after uninstall provider config mutation" if ENV["STRICT_TEST_FAIL_AFTER_UNINSTALL_CONFIGS"] == "1"
provider_config_records = sort_file_records(manifest.fetch("provider_config_records").map do |record|
  file_record(Pathname.new(record.fetch("path")), "provider-config", record.fetch("provider", ""))
end)
updated_manifest["provider_config_records"] = provider_config_records
updated_manifest["manifest_hash"] = json_hash(updated_manifest, "manifest_hash")
write_json(manifest_path, updated_manifest, "manifest_hash")
if updated_baseline
  updated_baseline["provider_config_records"] = provider_config_records
  updated_baseline["provider_config_paths"] = provider_config_records.map { |record| record.fetch("path") }.sort
  updated_baseline["install_manifest_hash"] = updated_manifest.fetch("manifest_hash")
  install_manifest_record = file_record(manifest_path, "install-manifest")
  updated_baseline["protected_file_inode_index"] = protected_file_inode_index([
    updated_baseline.fetch("runtime_file_records"),
    updated_baseline.fetch("runtime_config_records"),
    provider_config_records,
    updated_baseline.fetch("protected_config_records"),
    install_manifest_record
  ])
  updated_baseline["baseline_hash"] = json_hash(updated_baseline, "baseline_hash")
end
final_marker = marker.merge(
  "staged_install_manifest_hash" => updated_manifest.fetch("manifest_hash"),
  "staged_install_baseline_hash" => updated_baseline ? updated_baseline.fetch("baseline_hash") : ZERO_HASH,
  "provider_config_plan_hash" => Digest::SHA256.hexdigest(JSON.generate(provider_config_records.sort_by { |record| record.fetch("path") })),
  "updated_at" => now,
  "marker_hash" => ""
)
pending_before_marker_update = StrictModeGlobalLedger.fingerprint(pending_path)
write_json(pending_path, final_marker, "marker_hash")
write_json(baseline_path, updated_baseline, "baseline_hash") if updated_baseline
StrictModeGlobalLedger.append_backup_changes!(
  state_root,
  writer: "uninstall",
  backup_manifest: backup_manifest,
  kinds: %w[install-manifest install-baseline],
  related_record_hash: final_marker.fetch("marker_hash")
)
StrictModeGlobalLedger.append_change!(
  state_root,
  writer: "uninstall",
  target_path: pending_path,
  target_class: "installer-marker",
  old_fingerprint: pending_before_marker_update,
  new_fingerprint: StrictModeGlobalLedger.fingerprint(pending_path),
  related_record_hash: final_marker.fetch("marker_hash")
)
completion_started = true
complete_marker = StrictModeTransactionMarker.publish_complete_marker!(
  state_root: state_root,
  writer: "uninstall",
  complete_path: complete_path,
  marker: final_marker
)
raise "test fault after uninstall complete marker publication" if ENV["STRICT_TEST_FAIL_AFTER_UNINSTALL_COMPLETE_MARKER"] == "1"

StrictModeTransactionMarker.delete_pending_marker_after_complete!(state_root, "uninstall", pending_path, complete_marker)

puts "removed strict-mode discovery hooks for #{providers.join(", ")}"
rescue SystemCallError, RuntimeError, JSON::ParserError => e
  begin
    mark_uninstall_failed!(state_root, pending_path) unless completion_started
  rescue SystemCallError, RuntimeError, JSON::ParserError => marker_error
    warn "uninstall failed to publish uninstall-failed marker: #{marker_error.message}"
  end
  fail_uninstall(e.message)
ensure
  lock.release if lock
end
