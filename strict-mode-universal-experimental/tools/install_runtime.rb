#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "shellwords"
require "time"
require_relative "fixture_readiness_lib"
require_relative "global_ledger_lib"
require_relative "global_lock_lib"
require_relative "hook_entry_plan_lib"
require_relative "install_hook_plan_lib"
require_relative "metadata_lib"
require_relative "protected_config_lib"
require_relative "provider_config_fingerprint_lib"
require_relative "transaction_marker_lib"

ZERO_HASH = "0" * 64
PACKAGE_VERSION = "0.1.0-discovery-skeleton"

class DuplicateKeyHash < Hash
  def []=(key, value)
    raise "duplicate JSON object key: #{key}" if key?(key)

    super
  end
end

def usage_error(message)
  warn "install usage error: #{message}"
  exit 2
end

def fail_install(message)
  warn "install failed: #{message}"
  exit 1
end

def now
  Time.now.utc.iso8601
end

def expand_path(path)
  Pathname.new(File.expand_path(path)).cleanpath
end

def double_quote_shell(path)
  StrictModeInstallHookPlan.double_quote_shell(path)
end

def command_for(install_root, state_root, provider, logical_event, timeout_ms)
  StrictModeInstallHookPlan.command_for(install_root, state_root, provider, logical_event, timeout_ms)
end

def json_hash(record, field)
  clone = JSON.parse(JSON.generate(record))
  clone[field] = ""
  StrictModeMetadata.hash_record(clone, field)
end

def write_json(path, record, hash_field)
  record[hash_field] = json_hash(record, hash_field)
  path.dirname.mkpath
  tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
  tmp.write(JSON.pretty_generate(record) + "\n")
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def load_json_object!(path, label)
  raise "#{path}: #{label} must not be a symlink" if path.symlink?
  raise "#{path}: missing #{label}" unless path.file?

  record = JSON.parse(path.read, object_class: DuplicateKeyHash)
  raise "#{path}: #{label} must be a JSON object" unless record.is_a?(Hash)

  JSON.parse(JSON.generate(record))
rescue JSON::ParserError, RuntimeError => e
  raise "#{path}: malformed #{label}: #{e.message}"
end

def transition_pending_marker!(state_root, pending_path, phase, updates = {})
  current = load_json_object!(pending_path, "transaction marker")
  old_fingerprint = StrictModeGlobalLedger.fingerprint(pending_path)
  marker = current.merge(updates).merge(
    "phase" => phase,
    "updated_at" => now,
    "marker_hash" => ""
  )
  write_json(pending_path, marker, "marker_hash")
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "install",
    target_path: pending_path,
    target_class: "installer-marker",
    old_fingerprint: old_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(pending_path),
    related_record_hash: marker.fetch("marker_hash")
  )
  marker
end

def mark_install_failed!(state_root, pending_path, phase)
  return unless state_root && pending_path && pending_path.file?

  current = load_json_object!(pending_path, "transaction marker")
  return current if current.fetch("phase", "") == phase

  transition_pending_marker!(state_root, pending_path, phase)
end

def load_json(path)
  raise "#{path}: provider config must not be a symlink" if path.symlink?
  return {} unless path.exist?
  raise "#{path}: provider config is not a file" unless path.file?

  record = JSON.parse(path.read, object_class: DuplicateKeyHash)
  raise "#{path}: provider config must be a JSON object" unless record.is_a?(Hash)

  JSON.parse(JSON.generate(record))
rescue JSON::ParserError, RuntimeError => e
  raise "#{path}: malformed provider config: #{e.message}"
end

def write_provider_json(path, record)
  raise "#{path}: provider config must not be a symlink" if path.symlink?

  path.dirname.mkpath
  tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
  tmp.write(JSON.pretty_generate(record) + "\n")
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def sha256_file(path)
  return ZERO_HASH unless path.file?

  Digest::SHA256.file(path).hexdigest
end

def record_hash_or_zero(path)
  path.file? ? sha256_file(path) : ZERO_HASH
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
    kind = "file"
    content_sha256 = stat.file? ? sha256_file(active) : ZERO_HASH
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

def backup_subjects_for(providers, home, install_root, state_root)
  config_root = install_root.join("config")
  subjects = []
  providers.each do |provider|
    case provider
    when "claude"
      subjects << [home.join(".claude/settings.json"), "provider-config", provider]
    when "codex"
      subjects << [home.join(".codex/hooks.json"), "provider-config", provider]
      subjects << [home.join(".codex/config.toml"), "provider-config", provider]
    end
  end
  subjects << [config_root.join("runtime.env"), "runtime-config", ""]
  %w[
    protected-paths.txt
    filesystem-read-allowlist.txt
    network-allowlist.txt
    destructive-patterns.txt
    stub-allowlist.txt
    user-prompt-injection.md
    judge-prompt-template.md
  ].each do |name|
    subjects << [config_root.join(name), "protected-config", ""]
  end
  subjects << [install_root.join("install-manifest.json"), "install-manifest", ""]
  subjects << [state_root.join("protected-install-baseline.json"), "install-baseline", ""]
  subjects
end

def create_backup_manifest(install_root, state_root, active, transaction_id, providers, home, created_at)
  backup_dir = install_root.join("install-backups/#{transaction_id}")
  backup_dir.mkpath
  active_fingerprint = active_runtime_fingerprint(active)
  active_kind = active_fingerprint.fetch("kind")
  active_kind = "missing" unless %w[missing symlink directory].include?(active_kind)
  records = []
  provider_records = []
  protected_records = []
  runtime_records = []
  backup_subjects_for(providers, home, install_root, state_root).each do |path, kind, provider|
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

  manifest = {
    "schema_version" => 1,
    "transaction_id" => transaction_id,
    "created_at" => created_at,
    "install_root" => install_root.to_s,
    "state_root" => state_root.to_s,
    "previous_active_runtime_path" => active_fingerprint.fetch("path"),
    "previous_active_runtime_kind" => active_kind,
    "previous_active_runtime_fingerprint" => active_fingerprint.merge("kind" => active_kind),
    "previous_install_manifest_hash" => record_hash_or_zero(install_root.join("install-manifest.json")),
    "previous_install_baseline_hash" => record_hash_or_zero(state_root.join("protected-install-baseline.json")),
    "provider_config_records" => provider_records,
    "protected_config_records" => protected_records,
    "runtime_config_records" => runtime_records,
    "backup_file_records" => records,
    "manifest_hash" => ""
  }
  write_json(backup_dir.join("backup-manifest.json"), manifest, "manifest_hash")
  manifest
end

def runtime_file_records(release)
  sort_file_records(Dir.glob(release.join("**/*").to_s).sort.each_with_object([]) do |file, records|
    path = Pathname.new(file)
    next unless path.file?

    records << file_record(path, "runtime-file")
  end)
end

def ensure_config_files(install_root)
  config_root = install_root.join("config")
  config_root.mkpath
  templates = StrictModeMetadata.project_root.join("templates")
  {
    "runtime.env" => "runtime.env.example",
    "protected-paths.txt" => "protected-paths.txt",
    "filesystem-read-allowlist.txt" => "filesystem-read-allowlist.txt",
    "network-allowlist.txt" => "network-allowlist.txt",
    "destructive-patterns.txt" => "destructive-patterns.txt",
    "stub-allowlist.txt" => "stub-allowlist.txt",
    "user-prompt-injection.md" => "user-prompt-injection.md",
    "judge-prompt-template.md" => "judge-prompt-template.md"
  }.each do |target, template|
    path = config_root.join(target)
    raise "#{path}: protected config must not be a symlink" if path.symlink?
    next if path.exist?

    FileUtils.cp(templates.join(template), path)
    File.chmod(0o600, path)
  end
  config_root
end

def runtime_config_records(config_root)
  sort_file_records([file_record(config_root.join("runtime.env"), "runtime-config")])
end

def protected_config_records(config_root)
  sort_file_records(%w[
    protected-paths.txt
    filesystem-read-allowlist.txt
    network-allowlist.txt
    destructive-patterns.txt
    stub-allowlist.txt
    user-prompt-injection.md
    judge-prompt-template.md
  ].map { |name| file_record(config_root.join(name), "protected-config") })
end

def validate_config_files(config_root, install_root, state_root)
  mapping = {
    "runtime.env" => "runtime-env",
    "protected-paths.txt" => "protected-paths",
    "filesystem-read-allowlist.txt" => "filesystem-read-allowlist",
    "network-allowlist.txt" => "network-allowlist",
    "destructive-patterns.txt" => "destructive-patterns",
    "stub-allowlist.txt" => "stub-allowlist",
    "user-prompt-injection.md" => "user-prompt-injection",
    "judge-prompt-template.md" => "judge-prompt-template"
  }
  protected_roots = [install_root, state_root, config_root].map(&:to_s).uniq
  mapping.each do |file, kind|
    path = config_root.join(file)
    result = StrictModeProtectedConfig.parse_file(
      path,
      kind: kind,
      protected_roots: protected_roots
    )
    unless result.fetch("errors").empty?
      raise "#{path}: protected config validation failed: #{result.fetch("errors").join("; ")}"
    end
    result.fetch("config_errors").each do |message|
      warn "install config warning: #{path}: #{message}"
    end
  end
end

def preflight_existing_config_files(config_root, install_root, state_root)
  return unless config_root.exist? || config_root.symlink?
  raise "#{config_root}: protected config root must not be a symlink" if config_root.symlink?
  raise "#{config_root}: protected config root must be a directory" unless config_root.directory?

  mapping = {
    "runtime.env" => "runtime-env",
    "protected-paths.txt" => "protected-paths",
    "filesystem-read-allowlist.txt" => "filesystem-read-allowlist",
    "network-allowlist.txt" => "network-allowlist",
    "destructive-patterns.txt" => "destructive-patterns",
    "stub-allowlist.txt" => "stub-allowlist",
    "user-prompt-injection.md" => "user-prompt-injection",
    "judge-prompt-template.md" => "judge-prompt-template"
  }
  protected_roots = [install_root, state_root, config_root].map(&:to_s).uniq
  mapping.each do |file, kind|
    path = config_root.join(file)
    next unless path.exist? || path.symlink?
    raise "#{path}: protected config must not be a symlink" if path.symlink?
    raise "#{path}: protected config must be a file" unless path.file?

    result = StrictModeProtectedConfig.parse_file(
      path,
      kind: kind,
      protected_roots: protected_roots
    )
    unless result.fetch("errors").empty?
      raise "#{path}: protected config validation failed: #{result.fetch("errors").join("; ")}"
    end
  end
end

def hook_specs(provider, include_permission_request: false, include_subagent_stop: false)
  StrictModeInstallHookPlan.hook_specs(
    provider,
    include_permission_request: include_permission_request,
    include_subagent_stop: include_subagent_stop
  )
end

def managed_entries(provider, config_path, install_root, state_root, selected_output_contracts: [], enforce: false)
  StrictModeInstallHookPlan.managed_entries(
    provider,
    config_path,
    install_root,
    state_root: state_root,
    selected_output_contracts: selected_output_contracts,
    enforce: enforce
  )
end

def hook_config_entry(entry)
  StrictModeInstallHookPlan.hook_config_entry(entry)
end

def managed_command_identity(command)
  parts = Shellwords.split(command.to_s)
  hook_index = parts.index { |part| part.end_with?("/active/bin/strict-hook") }
  return nil unless hook_index
  return nil unless parts[hook_index + 1] == "--provider"

  provider = parts[hook_index + 2]
  logical_event = parts[hook_index + 3]
  return nil if provider.to_s.empty? || logical_event.to_s.empty?

  [parts[hook_index], provider, logical_event]
rescue ArgumentError
  nil
end

def remove_managed_hooks(root, entries)
  hooks = root["hooks"]
  return unless hooks.is_a?(Hash)

  commands = entries.map { |entry| entry.fetch("command") }
  managed_identities = entries.map { |entry| managed_command_identity(entry.fetch("command")) }.compact

  hooks.each_value do |entries|
    next unless entries.is_a?(Array)

    entries.reject! do |entry|
      hook_list = entry.is_a?(Hash) ? entry["hooks"] : nil
      next false unless hook_list.is_a?(Array)

      hook_list.reject! do |hook|
        next false unless hook.is_a?(Hash)

        command = hook["command"]
        commands.include?(command) || managed_identities.include?(managed_command_identity(command))
      end
      hook_list.empty?
    end
  end
end

def install_json_hooks(path, entries)
  root = load_json(path)
  root["hooks"] = {} unless root["hooks"].is_a?(Hash)
  remove_managed_hooks(root, entries)
  entries.each do |entry|
    event = entry.fetch("hook_event")
    root["hooks"][event] = [] unless root["hooks"][event].is_a?(Array)
    root["hooks"][event] << hook_config_entry(entry)
  end
  write_provider_json(path, root)
end

def parse_codex_hooks_feature_config(path)
  raise "#{path}: Codex config must not be a symlink" if path.symlink?
  return { "lines" => [], "features_seen" => false, "hooks_line" => nil, "deprecated_codex_lines" => [], "insert_at" => 0 } unless path.exist?
  raise "#{path}: Codex config must be a file" unless path.file?

  lines = path.read.lines
  section = nil
  features_seen = false
  hooks_line = nil
  deprecated_codex_lines = []
  insert_at = nil
  lines.each_with_index do |line, index|
    if (match = line.match(/\A\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?\z/))
      if section == "features" && insert_at.nil?
        insert_at = index
      end
      section = match[1]
      if section == "features"
        raise "#{path}: duplicate [features] table" if features_seen

        features_seen = true
      end
      next
    end

    next unless section == "features"
    next if line.strip.empty? || line.lstrip.start_with?("#")

    key = line.split("=", 2).first&.strip
    if key == "hooks"
      raise "#{path}: duplicate hooks key" unless hooks_line.nil?

      hooks_line = index
    elsif key == "codex_hooks"
      deprecated_codex_lines << index
    end
  end
  {
    "lines" => lines,
    "features_seen" => features_seen,
    "hooks_line" => hooks_line,
    "deprecated_codex_lines" => deprecated_codex_lines,
    "insert_at" => insert_at || lines.length
  }
end

def preflight_provider_configs(providers, home)
  providers.each do |provider|
    case provider
    when "claude"
      load_json(home.join(".claude/settings.json"))
    when "codex"
      load_json(home.join(".codex/hooks.json"))
      parse_codex_hooks_feature_config(home.join(".codex/config.toml"))
    end
  end
end

def ensure_codex_hooks_feature(path)
  path.dirname.mkpath
  raise "#{path}: Codex config must not be a symlink" if path.symlink?

  unless path.exist?
    path.write("[features]\nhooks = true\n")
    File.chmod(0o600, path)
    return
  end

  parsed = parse_codex_hooks_feature_config(path)
  lines = parsed.fetch("lines")
  features_seen = parsed.fetch("features_seen")
  hooks_line = parsed.fetch("hooks_line")
  deprecated_codex_lines = parsed.fetch("deprecated_codex_lines")
  insert_at = parsed.fetch("insert_at")

  rebuilt_lines = []
  lines.each_with_index do |line, index|
    next if deprecated_codex_lines.include?(index)

    rebuilt_lines << (index == hooks_line ? "hooks = true\n" : line)
  end
  lines = rebuilt_lines

  if hooks_line.nil?
    if features_seen
      target_insert_at = deprecated_codex_lines.empty? ? insert_at : deprecated_codex_lines.first
      deleted_before_insert = deprecated_codex_lines.count { |index| index < target_insert_at }
      lines.insert(target_insert_at - deleted_before_insert, "hooks = true\n")
    else
      lines << "\n" unless lines.empty? || lines.last.end_with?("\n\n")
      lines << "[features]\n"
      lines << "hooks = true\n"
    end
  end

  tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
  tmp.write(lines.join)
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def copy_release(release)
  root = StrictModeMetadata.project_root
  %w[bin lib core schemas matrices templates providers tools].each do |dir|
    source = root.join(dir)
    next unless source.directory?

    FileUtils.mkdir_p(release)
    FileUtils.cp_r(source, release)
  end
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

def provider_hook_config_path(provider, home)
  case provider
  when "claude"
    home.join(".claude/settings.json")
  when "codex"
    home.join(".codex/hooks.json")
  else
    raise "unsupported provider #{provider.inspect}"
  end
end

def provider_config_plan_paths(providers, home)
  providers.flat_map do |provider|
    case provider
    when "claude"
      [home.join(".claude/settings.json")]
    when "codex"
      [home.join(".codex/hooks.json"), home.join(".codex/config.toml")]
    else
      raise "unsupported provider #{provider.inspect}"
    end
  end.map(&:to_s).sort
end

def provider_version_plan(providers, provider_versions)
  providers.each_with_object({}) do |provider, result|
    result[provider] = provider_versions.fetch(provider, "unknown")
  end
end

def provider_build_hash_plan(providers, provider_build_hashes)
  providers.each_with_object({}) do |provider, result|
    result[provider] = provider_build_hashes.fetch(provider, "")
  end
end

def build_install_plan(home, install_root, state_root, providers, enforce:, provider_versions: {}, provider_build_hashes: {})
  selected_output_contracts = enforce ? StrictModeFixtureReadiness.selected_output_contracts(StrictModeMetadata.project_root, providers, provider_versions, provider_build_hashes) : []
  provider_entries = providers.flat_map do |provider|
    managed_entries(
      provider,
      provider_hook_config_path(provider, home),
      install_root,
      state_root,
      selected_output_contracts: selected_output_contracts,
      enforce: enforce
    )
  end
  provider_entries = StrictModeHookEntryPlan.sort_entries(provider_entries)
  {
    "schema_version" => 1,
    "plan_kind" => "install-plan",
    "plan_only" => true,
    "enforce" => enforce,
    "providers" => providers,
    "provider_versions" => provider_version_plan(providers, provider_versions),
    "provider_build_hashes" => provider_build_hash_plan(providers, provider_build_hashes),
    "install_root" => install_root.to_s,
    "state_root" => state_root.to_s,
    "active_runtime_link" => install_root.join("active").to_s,
    "provider_config_paths" => provider_config_plan_paths(providers, home),
    "managed_hook_entries" => provider_entries,
    "generated_hook_commands" => provider_entries.map { |entry| entry.slice("provider", "hook_event", "logical_event", "command") },
    "generated_hook_env" => {
      "STRICT_HOOK_TIMEOUT_MS" => "per-hook command prefix",
      "STRICT_ENFORCING_HOOK" => "per-enforcing hook command prefix",
      "STRICT_OUTPUT_CONTRACT_ID" => "per-enforcing hook command prefix",
      "STRICT_STATE_ROOT" => "per-install command prefix"
    },
    "fixture_manifest_records" => StrictModeFixtureReadiness.fixture_manifest_records(StrictModeMetadata.project_root, providers),
    "selected_output_contracts" => selected_output_contracts
  }
end

options = {
  provider: "auto",
  install_root: ENV["STRICT_INSTALL_ROOT"],
  state_root: ENV["STRICT_STATE_ROOT"],
  enforce: false,
  allow_blocking_enforce: false,
  plan_only: false,
  provider_versions: {},
  provider_build_hashes: {}
}

begin
  OptionParser.new do |opts|
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--install-root PATH") { |value| options[:install_root] = value }
    opts.on("--state-root PATH") { |value| options[:state_root] = value }
    opts.on("--enforce") { options[:enforce] = true }
    opts.on("--allow-blocking-enforce") { options[:allow_blocking_enforce] = true }
    opts.on("--plan-only") { options[:plan_only] = true }
    opts.on("--dry-run") { options[:plan_only] = true }
    opts.on("--provider-version PROVIDER=VERSION") do |value|
      provider, version = StrictModeFixtureReadiness.parse_provider_version_assignment(value)
      options[:provider_versions][provider] = version
    end
    opts.on("--provider-build-hash PROVIDER=SHA256") do |value|
      provider, build_hash = StrictModeFixtureReadiness.parse_provider_build_hash_assignment(value)
      options[:provider_build_hashes][provider] = build_hash
    end
  end.parse!(ARGV)
rescue OptionParser::ParseError, ArgumentError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?

home = expand_path(ENV.fetch("HOME"))
install_root = expand_path(options[:install_root] || home.join(".strict-mode"))
state_root = expand_path(options[:state_root] || install_root.join("state"))
fail_install("install root must not contain NUL, newline, or carriage return") if install_root.to_s.match?(/[\0\n\r]/)
fail_install("state root must not contain NUL, newline, or carriage return") if state_root.to_s.match?(/[\0\n\r]/)
providers = provider_list(options[:provider])
begin
  StrictModeFixtureReadiness.validate_provider_versions!(options[:provider_versions], providers)
  StrictModeFixtureReadiness.validate_provider_build_hashes!(options[:provider_build_hashes], providers)
rescue ArgumentError => e
  usage_error(e.message)
end
selected_output_contracts = []
if options[:enforce]
  readiness_errors = StrictModeFixtureReadiness.enforcing_errors(StrictModeMetadata.project_root, providers, options[:provider_versions], options[:provider_build_hashes])
  unless readiness_errors.empty?
    fail_install("enforcing activation fixture readiness failed:\n#{readiness_errors.map { |error| "- #{error}" }.join("\n")}")
  end
  selected_output_contracts = StrictModeFixtureReadiness.selected_output_contracts(StrictModeMetadata.project_root, providers, options[:provider_versions], options[:provider_build_hashes])
  if options[:plan_only]
    puts JSON.pretty_generate(build_install_plan(home, install_root, state_root, providers, enforce: true, provider_versions: options[:provider_versions], provider_build_hashes: options[:provider_build_hashes]))
    exit 0
  end
  unless options[:allow_blocking_enforce]
    fail_install("--enforce real activation installs blocking PreToolUse/Stop hooks; rerun with --allow-blocking-enforce after reviewing --enforce --plan-only output")
  end
end
if options[:plan_only]
  puts JSON.pretty_generate(build_install_plan(home, install_root, state_root, providers, enforce: false, provider_versions: options[:provider_versions], provider_build_hashes: options[:provider_build_hashes]))
  exit 0
end
transaction_id = "#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{$$}-#{SecureRandom.hex(4)}"
release = install_root.join("releases/#{transaction_id}")
active = install_root.join("active")
lock = nil
pending_path = nil
install_failure_phase = nil

begin
  lock = StrictModeGlobalLock.acquire!(install_root, state_root: state_root, transaction_kind: "install")
  StrictModeGlobalLedger.verify_chain!(state_root)
  StrictModeTransactionMarker.cleanup_completed_pending_markers!(state_root: state_root, install_root: install_root)
  StrictModeTransactionMarker.repair_completed_marker_ledgers!(state_root: state_root, install_root: install_root)
  StrictModeTransactionMarker.assert_no_pending_markers!(install_root)
  if active.exist? && !active.symlink?
    fail_install("#{active}: active runtime must be missing or a symlink in the discovery skeleton")
  end
  preflight_provider_configs(providers, home)
  preflight_existing_config_files(install_root.join("config"), install_root, state_root)

  copy_release(release)
  state_root.mkpath
  config_root = install_root.join("config")
  created_at = now
  manifest_path = install_root.join("install-manifest.json")
  previous_manifest_hash = record_hash_or_zero(manifest_path)
  baseline_path = state_root.join("protected-install-baseline.json")
  previous_baseline_hash = record_hash_or_zero(baseline_path)
  backup_manifest = create_backup_manifest(install_root, state_root, active, transaction_id, providers, home, created_at)
  marker_dir = install_root.join("install-transactions")
  pending_path = marker_dir.join("#{transaction_id}.pending.json")
  complete_path = marker_dir.join("#{transaction_id}.complete.json")
  pending_marker = {
    "schema_version" => 1,
    "transaction_id" => transaction_id,
    "phase" => "pre-activation",
    "install_root" => install_root.to_s,
    "state_root" => state_root.to_s,
    "staged_runtime_path" => release.to_s,
    "previous_active_runtime_path" => backup_manifest.fetch("previous_active_runtime_path"),
    "previous_install_manifest_hash" => previous_manifest_hash,
    "previous_install_baseline_hash" => previous_baseline_hash,
    "backup_manifest_hash" => backup_manifest.fetch("manifest_hash"),
    "staged_install_manifest_hash" => ZERO_HASH,
    "staged_install_baseline_hash" => ZERO_HASH,
    "provider_config_plan_hash" => ZERO_HASH,
    "created_at" => created_at,
    "updated_at" => created_at,
    "marker_hash" => ""
  }
  write_json(pending_path, pending_marker, "marker_hash")
  backup_manifest_path = install_root.join("install-backups/#{transaction_id}/backup-manifest.json")
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "install",
    target_path: release,
    target_class: "install-release",
    old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(release),
    related_record_hash: pending_marker.fetch("marker_hash")
  )
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "install",
    target_path: backup_manifest_path,
    target_class: "installer-backup",
    old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(backup_manifest_path),
    related_record_hash: backup_manifest.fetch("manifest_hash")
  )
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "install",
    target_path: pending_path,
    target_class: "installer-marker",
    old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(pending_path),
    related_record_hash: pending_marker.fetch("marker_hash")
  )
  raise "test fault after pending marker publication" if ENV["STRICT_TEST_FAIL_AFTER_PENDING_MARKER"] == "1"

  install_failure_phase = "post-activation-failed"
  pending_marker = transition_pending_marker!(state_root, pending_path, "activating")
  config_root = ensure_config_files(install_root)
  validate_config_files(config_root, install_root, state_root)
  StrictModeGlobalLedger.append_backup_changes!(
    state_root,
    writer: "install",
    backup_manifest: backup_manifest,
    kinds: %w[runtime-config protected-config],
    related_record_hash: pending_marker.fetch("marker_hash")
  )

  provider_entries = []
  provider_config_paths = {}
  provider_record_paths = {}
  providers.each do |provider|
    case provider
    when "claude"
      path = home.join(".claude/settings.json")
      entries = managed_entries(provider, path, install_root, state_root, selected_output_contracts: selected_output_contracts, enforce: options[:enforce])
      install_json_hooks(path, entries)
      provider_entries.concat(entries)
      provider_config_paths[provider] = path
      provider_record_paths["#{provider}:hooks"] = [provider, path]
    when "codex"
      hooks_path = home.join(".codex/hooks.json")
      config_path = home.join(".codex/config.toml")
      ensure_codex_hooks_feature(config_path)
      entries = managed_entries(provider, hooks_path, install_root, state_root, selected_output_contracts: selected_output_contracts, enforce: options[:enforce])
      install_json_hooks(hooks_path, entries)
      provider_entries.concat(entries)
      provider_config_paths[provider] = hooks_path
      provider_record_paths["#{provider}:hooks"] = [provider, hooks_path]
      provider_record_paths["#{provider}:config"] = [provider, config_path]
    end
  end
  StrictModeGlobalLedger.append_backup_changes!(
    state_root,
    writer: "install",
    backup_manifest: backup_manifest,
    kinds: %w[provider-config],
    related_record_hash: pending_marker.fetch("marker_hash")
  )
  raise "test fault after provider config mutation" if ENV["STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS"] == "1"

  tmp_link = install_root.join(".active.tmp-#{$$}-#{SecureRandom.hex(4)}")
  FileUtils.rm_f(tmp_link)
  File.symlink(release.to_s, tmp_link)
  File.rename(tmp_link, active)
  StrictModeGlobalLedger.append_backup_changes!(
    state_root,
    writer: "install",
    backup_manifest: backup_manifest,
    kinds: %w[active-runtime],
    related_record_hash: pending_marker.fetch("marker_hash")
  )
  raise "test fault after active runtime link mutation" if ENV["STRICT_TEST_FAIL_AFTER_ACTIVE_LINK"] == "1"

  provider_config_records = sort_file_records(provider_record_paths.values.map { |provider, path| file_record(path, "provider-config", provider) })
  runtime_records = runtime_file_records(release)
  runtime_config = runtime_config_records(config_root)
  protected_config = protected_config_records(config_root)
  fixture_manifest_records = StrictModeFixtureReadiness.fixture_manifest_records(StrictModeMetadata.project_root, providers)

  manifest = {
    "schema_version" => 1,
    "transaction_id" => transaction_id,
    "install_root" => install_root.to_s,
    "active_runtime_link" => active.to_s,
    "active_runtime_target" => release.to_s,
    "state_root" => state_root.to_s,
    "config_root" => config_root.to_s,
    "package_version" => PACKAGE_VERSION,
    "managed_hook_entries" => provider_entries,
    "runtime_file_records" => runtime_records,
    "runtime_config_records" => runtime_config,
    "provider_config_records" => provider_config_records,
    "protected_config_records" => protected_config,
    "fixture_manifest_records" => fixture_manifest_records,
    "selected_output_contracts" => selected_output_contracts,
    "created_at" => created_at,
    "updated_at" => created_at,
    "manifest_hash" => ""
  }

  write_json(manifest_path, manifest, "manifest_hash")
  install_manifest_record = file_record(manifest_path, "install-manifest")

  baseline = {
    "schema_version" => 1,
    "kind" => "protected-install-baseline",
    "transaction_id" => transaction_id,
    "install_root" => install_root.to_s,
    "active_runtime_link" => active.to_s,
    "active_runtime_target" => release.to_s,
    "state_root" => state_root.to_s,
    "config_root" => config_root.to_s,
    "provider_config_paths" => provider_config_records.map { |record| record.fetch("path") }.sort,
    "managed_hook_entries" => provider_entries,
    "generated_hook_commands" => provider_entries.map { |entry| entry.slice("provider", "hook_event", "logical_event", "command") },
    "generated_hook_env" => {
      "STRICT_HOOK_TIMEOUT_MS" => "per-hook command prefix",
      "STRICT_ENFORCING_HOOK" => "per-enforcing hook command prefix",
      "STRICT_OUTPUT_CONTRACT_ID" => "per-enforcing hook command prefix",
      "STRICT_STATE_ROOT" => "per-install command prefix"
    },
    "package_version" => PACKAGE_VERSION,
    "install_manifest_hash" => manifest.fetch("manifest_hash"),
    "runtime_file_records" => runtime_records,
    "runtime_config_records" => runtime_config,
    "provider_config_records" => provider_config_records,
    "protected_config_records" => protected_config,
    "fixture_manifest_records" => fixture_manifest_records,
    "selected_output_contracts" => selected_output_contracts,
    "protected_file_inode_index" => protected_file_inode_index([runtime_records, runtime_config, provider_config_records, protected_config, install_manifest_record]),
    "created_at" => created_at,
    "updated_at" => created_at,
    "baseline_hash" => ""
  }
  write_json(baseline_path, baseline, "baseline_hash")
  StrictModeGlobalLedger.append_backup_changes!(
    state_root,
    writer: "install",
    backup_manifest: backup_manifest,
    kinds: %w[install-manifest install-baseline],
    related_record_hash: baseline.fetch("baseline_hash")
  )

  marker = transition_pending_marker!(
    state_root,
    pending_path,
    pending_marker.fetch("phase"),
    {
      "staged_install_manifest_hash" => manifest.fetch("manifest_hash"),
      "staged_install_baseline_hash" => baseline.fetch("baseline_hash"),
      "provider_config_plan_hash" => Digest::SHA256.hexdigest(JSON.generate(provider_config_records.sort_by { |record| record.fetch("path") }))
    }
  )
  install_failure_phase = nil
  complete_marker = StrictModeTransactionMarker.publish_complete_marker!(
    state_root: state_root,
    writer: "install",
    complete_path: complete_path,
    marker: marker
  )
  raise "test fault after install complete marker publication" if ENV["STRICT_TEST_FAIL_AFTER_INSTALL_COMPLETE_MARKER"] == "1"

  StrictModeTransactionMarker.delete_pending_marker_after_complete!(state_root, "install", pending_path, complete_marker)

  mode = options[:enforce] ? "enforcing" : "discovery"
  puts "installed strict-mode #{mode} runtime at #{install_root}"
rescue SystemCallError, RuntimeError, JSON::ParserError => e
  failure_message = e.message
  begin
    mark_install_failed!(state_root, pending_path, install_failure_phase) if install_failure_phase
  rescue SystemCallError, RuntimeError, JSON::ParserError => marker_error
    failure_message = "#{failure_message}; additionally failed to publish #{install_failure_phase} marker: #{marker_error.message}"
  end
  fail_install(failure_message)
ensure
  lock.release if lock
end
