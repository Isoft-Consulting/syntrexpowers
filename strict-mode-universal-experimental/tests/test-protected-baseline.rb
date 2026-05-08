#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../tools/destructive_gate_lib"
require_relative "../tools/metadata_lib"
require_relative "../tools/protected_baseline_lib"

ROOT = StrictModeMetadata.project_root
INSTALL = ROOT.join("install.sh")

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def assert_no_stacktrace(name, output)
  return unless output.match?(/(^|\n)\S+\.rb:\d+:in `/) || output.include?("\n\tfrom ")

  record_failure(name, "unexpected Ruby stacktrace", output)
end

def run_cmd(env, *args)
  stdout, stderr, status = Open3.capture3(env, *args.map(&:to_s))
  [status.exitstatus, stdout + stderr]
end

def read_json(path)
  JSON.parse(path.read)
end

def hash_record(record, field)
  clone = JSON.parse(JSON.generate(record))
  clone[field] = ""
  StrictModeMetadata.hash_record(clone, field)
end

def write_hash_bound_json(path, record, field)
  record[field] = hash_record(record, field)
  path.write(JSON.pretty_generate(record) + "\n")
end

def write_file(path, bytes)
  path.dirname.mkpath
  path.write(bytes)
  path
end

def atomic_rewrite(path, bytes)
  tmp = path.dirname.join(".#{path.basename}.tmp")
  tmp.write(bytes)
  File.chmod(0o600, tmp)
  File.rename(tmp, path)
end

def rewrite_inode_index_provider!(baseline, path, kind, provider)
  baseline.fetch("protected_file_inode_index").each_value do |entries|
    entries.each do |entry|
      next unless entry.fetch("path") == path && entry.fetch("kind") == kind

      entry["provider"] = provider
    end
  end
end

def with_install(provider: "all", before_install: nil)
  $cases += 1
  Dir.mktmpdir("strict-protected-baseline-") do |dir|
    root = Pathname.new(dir).realpath
    home = root.join("home")
    install_root = root.join("strict root")
    project = root.join("project")
    project.join(".strict-mode").mkpath
    home.join(".claude").mkpath
    home.join(".codex").mkpath
    home.join(".claude/settings.json").write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
    home.join(".codex/hooks.json").write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
    home.join(".codex/config.toml").write("[features]\nexisting = true\n")
    before_install.call(root, home, install_root, project) if before_install
    status, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", provider, "--install-root", install_root)
    assert_no_stacktrace("install fixture", output)
    raise "install failed: #{output}" unless status.zero?

    yield root, home, install_root, install_root.join("state"), project
  end
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected baseline loader trusts fresh install output"
  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, loaded.fetch("trusted"), "fresh install should load trusted", loaded.fetch("errors").join("\n"))
  roots = loaded.fetch("protected_roots")
  baseline = read_json(state_root.join("protected-install-baseline.json"))
  assert(name, roots.include?(install_root.to_s), "install_root missing from protected roots")
  assert(name, roots.include?(state_root.to_s), "state_root missing from protected roots")
  assert(name, roots.include?(install_root.join("config").to_s), "config_root missing from protected roots")
  assert(name, roots.include?(install_root.join("active").to_s), "active link missing from protected roots")
  assert(name, roots.include?(project.join(".strict-mode").to_s), "project .strict-mode missing from protected roots")
  assert(name, roots.include?(home.join(".codex/hooks.json").to_s), "provider config path missing from protected roots")
  assert(name, !baseline.fetch("protected_file_inode_index").empty?, "installer wrote empty protected inode index")
  assert(name, loaded.fetch("protected_inodes").any? { |entry| entry.fetch("path") == install_root.join("config/runtime.env").to_s }, "runtime.env inode missing")
  assert(name, loaded.fetch("protected_inodes").any? { |entry| entry.fetch("kind") == "install-manifest" && entry.fetch("path") == install_root.join("install-manifest.json").to_s }, "install manifest inode missing")
  assert(name, loaded.fetch("destructive_patterns").empty?, "comment-only destructive template should load empty records")
end

with_install(provider: "codex") do |_root, home, install_root, _state_root, project|
  name = "codex hook trust state can change without invalidating protected config"
  config = home.join(".codex/config.toml")
  hook_key = "#{home}/.codex/hooks.json:pre_tool_use:0:0"
  atomic_rewrite(config, "#{config.read}\n[hooks.state]\n\n[hooks.state.\"#{hook_key}\"]\ntrusted_hash = \"sha256:#{"a" * 64}\"\n")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, loaded.fetch("trusted"), "Codex hooks.state drift should remain trusted", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("protected_inodes").any? { |entry| entry.fetch("path") == config.to_s && entry.fetch("mutable_provider_state") == true }, "mutable Codex config.toml current inode missing")

  alias_path = project.join("codex-config-hardlink")
  File.link(config, alias_path)
  direct = StrictModeDestructiveGate.classify_tool(
    { "kind" => "write", "file_path" => alias_path.to_s },
    cwd: project,
    project_dir: project,
    protected_roots: loaded.fetch("protected_roots"),
    protected_inodes: loaded.fetch("protected_inodes"),
    destructive_patterns: loaded.fetch("destructive_patterns"),
    home: home,
    install_root: install_root
  )
  assert(name, direct.fetch("decision") == "block" && direct.fetch("reason_code") == "protected-root", "Codex config hardlink alias did not block", direct.inspect)
end

with_install(provider: "codex") do |_root, home, install_root, _state_root, project|
  name = "codex non-state config drift remains protected"
  config = home.join(".codex/config.toml")
  hook_state = "\n[hooks.state]\n\n[hooks.state.\"#{home}/.codex/hooks.json:pre_tool_use:0:0\"]\ntrusted_hash = \"sha256:#{"b" * 64}\"\n"
  atomic_rewrite(config, config.read.sub("codex_hooks = true", "codex_hooks = false") + hook_state)

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "Codex feature flag drift loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("content_sha256 mismatch") }, "missing Codex stable content diagnostic", loaded.fetch("errors").join("\n"))
end

custom_config = lambda do |_root, _home, install_root, project|
  config_root = install_root.join("config")
  protected_tree = project.join("protected-tree")
  protected_file = write_file(project.join("protected-file.txt"), "locked\n")
  protected_tree.mkpath
  write_file(config_root.join("protected-paths.txt"), "protect-file #{protected_file}\nprotect-tree #{protected_tree}/**\n")
  write_file(config_root.join("destructive-patterns.txt"), "shell-ere git[[:space:]]+reset[[:space:]]+--hard\nargv-token rm\n")
end

with_install(before_install: custom_config) do |_root, home, install_root, _state_root, project|
  name = "loader exposes configured protected paths and destructive patterns to classifier"
  loaded = StrictModeProtectedBaseline.load!(install_root: install_root, project_dir: project, home: home)
  assert(name, loaded.fetch("protected_roots").include?(project.join("protected-file.txt").to_s), "protect-file root missing")
  assert(name, loaded.fetch("protected_roots").include?(project.join("protected-tree").to_s), "protect-tree root missing")
  assert(name, loaded.fetch("destructive_patterns").size == 2, "destructive patterns missing")

  direct = StrictModeDestructiveGate.classify_tool(
    { "kind" => "write", "file_path" => project.join("protected-file.txt").to_s },
    cwd: project,
    project_dir: project,
    protected_roots: loaded.fetch("protected_roots"),
    protected_inodes: loaded.fetch("protected_inodes"),
    destructive_patterns: loaded.fetch("destructive_patterns"),
    home: home,
    install_root: install_root
  )
  assert(name, direct.fetch("decision") == "block" && direct.fetch("reason_code") == "protected-root", "configured protect-file did not block", direct.inspect)

  shell = StrictModeDestructiveGate.classify_tool(
    { "kind" => "shell", "command" => "git reset --hard HEAD" },
    cwd: project,
    project_dir: project,
    protected_roots: loaded.fetch("protected_roots"),
    protected_inodes: loaded.fetch("protected_inodes"),
    destructive_patterns: loaded.fetch("destructive_patterns"),
    home: home,
    install_root: install_root
  )
  assert(name, shell.fetch("decision") == "block" && shell.fetch("reason_code") == "destructive-command", "configured destructive pattern did not block", shell.inspect)
end

with_install do |_root, home, install_root, _state_root, project|
  name = "manifest hash tamper makes protected baseline untrusted"
  manifest_path = install_root.join("install-manifest.json")
  manifest = read_json(manifest_path)
  manifest["package_version"] = "tampered"
  manifest_path.write(JSON.pretty_generate(manifest) + "\n")
  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "tampered manifest loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("manifest_hash mismatch") }, "missing manifest hash diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "managed hook plan drift makes protected baseline untrusted"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  entries = manifest.fetch("managed_hook_entries")
  pre_tool = entries.find { |entry| entry.fetch("provider") == "codex" && entry.fetch("logical_event") == "pre-tool-use" }
  pre_tool["enforcing"] = true
  pre_tool["output_contract_id"] = "missing.codex.pre.block"
  manifest["managed_hook_entries"] = entries
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["managed_hook_entries"] = entries
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "invalid managed hook plan loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("managed hook entry plan invalid") }, "missing hook plan diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "managed hook command outside install root makes protected baseline untrusted"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  entries = manifest.fetch("managed_hook_entries")
  stop = entries.find { |entry| entry.fetch("provider") == "codex" && entry.fetch("logical_event") == "stop" }
  stop["command"] = "STRICT_HOOK_TIMEOUT_MS=60000 STRICT_STATE_ROOT=\"#{state_root}\" \"/tmp/other-strict/active/bin/strict-hook\" --provider codex stop"
  stop["removal_selector"] = StrictModeHookEntryPlan.removal_selector_for(stop)
  manifest["managed_hook_entries"] = entries
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["managed_hook_entries"] = entries
  baseline["generated_hook_commands"] = entries.map do |entry|
    {
      "provider" => entry.fetch("provider"),
      "hook_event" => entry.fetch("hook_event"),
      "logical_event" => entry.fetch("logical_event"),
      "command" => entry.fetch("command")
    }
  end
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "outside-root hook command loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("command hook path must match install_root active strict-hook") }, "missing outside-root hook command diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "manifest and baseline extra top-level fields are rejected after hash recompute"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  manifest["unexpected"] = true
  baseline["unexpected"] = true
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "extra top-level fields loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("install-manifest.json: top-level fields mismatch") && message.include?("extra unexpected") }, "missing manifest extra-field diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("protected-install-baseline.json: top-level fields mismatch") && message.include?("extra unexpected") }, "missing baseline extra-field diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "manifest and baseline top-level value types are rejected after hash recompute"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  manifest["schema_version"] = "1"
  baseline["schema_version"] = "1"
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "bad top-level value types loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("install-manifest.json: schema_version must be 1") }, "missing manifest schema_version diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("protected-install-baseline.json: schema_version must be 1") }, "missing baseline schema_version diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "manifest and baseline nested records must match after hash recompute"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  manifest["runtime_config_records"] = []
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "manifest/baseline nested record drift loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("manifest/baseline runtime_config_records mismatch") }, "missing runtime_config_records mismatch diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, _state_root, project|
  name = "protected file content tamper makes baseline untrusted"
  install_root.join("config/runtime.env").write("STRICT_CAPTURE_RAW_PAYLOADS=1\n")
  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "tampered runtime.env loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("content_sha256 mismatch") }, "missing content hash diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected file inode drift makes baseline untrusted"
  provider_config = home.join(".codex/hooks.json")
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  stale_inode = provider_config.stat.ino + 1

  [manifest, baseline].each do |record|
    provider_record = record.fetch("provider_config_records").find { |entry| entry.fetch("path") == provider_config.to_s }
    provider_record["inode"] = stale_inode
  end
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "inode drift loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("dev/inode mismatch") }, "missing inode drift diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected inode index value drift is rejected after hash recompute"
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  key = baseline.fetch("protected_file_inode_index").keys.sort.fetch(0)
  baseline.fetch("protected_file_inode_index").fetch(key).first["path"] = "#{baseline.fetch("protected_file_inode_index").fetch(key).first.fetch("path")}.tampered"
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "inode index value drift loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("protected_file_inode_index entry mismatch") }, "missing inode index mismatch diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected inode index duplicate entries are rejected after hash recompute"
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  key = baseline.fetch("protected_file_inode_index").keys.sort.fetch(0)
  entry = JSON.parse(JSON.generate(baseline.fetch("protected_file_inode_index").fetch(key).first))
  baseline.fetch("protected_file_inode_index").fetch(key) << entry
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "duplicate inode index entry loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("protected_file_inode_index #{key} contains duplicate entries") }, "missing duplicate inode index diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected file records reject extra fields after hash recompute"
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  baseline.fetch("runtime_config_records").first["unexpected"] = true
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "extra nested file record loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("file record fields mismatch") }, "missing file record field diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected file records reject stale size and noncanonical path after hash recompute"
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  runtime_record = baseline.fetch("runtime_config_records").first
  runtime_path = Pathname.new(runtime_record.fetch("path"))
  runtime_record["path"] = "#{runtime_path.dirname}/../#{runtime_path.dirname.basename}/#{runtime_path.basename}"
  baseline.fetch("protected_config_records").first["size_bytes"] = 0
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "stale or noncanonical file record loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("file record path must be canonical") }, "missing canonical path diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("size_bytes mismatch") }, "missing size_bytes diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected file records reject invalid provider kind coupling after hash recompute"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  provider_record = baseline.fetch("provider_config_records").find { |record| record.fetch("provider") == "codex" }
  provider_record["provider"] = ""
  manifest.fetch("provider_config_records").find { |record| record.fetch("path") == provider_record.fetch("path") }["provider"] = ""
  rewrite_inode_index_provider!(baseline, provider_record.fetch("path"), provider_record.fetch("kind"), "")
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "invalid provider-config provider loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("file record provider invalid for provider-config") }, "missing provider/kind diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "protected file records reject duplicate and unsorted arrays after hash recompute"
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  baseline.fetch("runtime_config_records") << JSON.parse(JSON.generate(baseline.fetch("runtime_config_records").first))
  baseline["protected_config_records"] = baseline.fetch("protected_config_records").reverse
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "duplicate or unsorted nested file records loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("runtime_config_records duplicate path/kind") }, "missing duplicate file record diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("protected_config_records must be sorted by path/kind") }, "missing unsorted file record diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "fixture manifest records reject extra fields and duplicate tuples after hash recompute"
  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  record = {
    "provider" => "codex",
    "provider_version" => "unknown",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => "stop",
    "contract_kind" => "payload-schema",
    "contract_id" => "codex.stop.payload",
    "fixture_record_hash" => "a" * 64,
    "fixture_manifest_hash" => "b" * 64
  }
  records = [record.merge("unexpected" => true), record, JSON.parse(JSON.generate(record))]
  manifest["fixture_manifest_records"] = records
  baseline["fixture_manifest_records"] = records
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "malformed fixture manifest records loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("fixture_manifest_records 0: record fields mismatch") }, "missing fixture record field diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("fixture_manifest_records duplicate tuples") }, "missing fixture duplicate diagnostic", loaded.fetch("errors").join("\n"))
end

with_install do |_root, home, install_root, state_root, project|
  name = "baseline derived provider paths commands and env are verified"
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  baseline["provider_config_paths"] << home.join(".codex/extra-hooks.json").to_s
  baseline["generated_hook_commands"].first["command"] = "echo tampered"
  baseline["generated_hook_env"]["STRICT_HOOK_TIMEOUT_MS"] = "tampered"
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  loaded = StrictModeProtectedBaseline.load(install_root: install_root, project_dir: project, home: home)
  assert(name, !loaded.fetch("trusted"), "derived baseline fields loaded as trusted")
  assert(name, loaded.fetch("errors").any? { |message| message.include?("provider_config_paths mismatch") }, "missing provider_config_paths mismatch diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("generated_hook_commands mismatch") }, "missing generated_hook_commands mismatch diagnostic", loaded.fetch("errors").join("\n"))
  assert(name, loaded.fetch("errors").any? { |message| message.include?("generated_hook_env mismatch") }, "missing generated_hook_env mismatch diagnostic", loaded.fetch("errors").join("\n"))
end

if $failures.empty?
  puts "protected baseline tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
