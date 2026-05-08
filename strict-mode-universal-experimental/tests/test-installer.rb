#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/decision_contract_lib"
require_relative "../tools/fixture_manifest_lib"
require_relative "../tools/global_ledger_lib"
require_relative "../tools/global_lock_lib"
require_relative "../tools/hook_entry_plan_lib"
require_relative "../tools/metadata_lib"

ROOT = StrictModeMetadata.project_root
INSTALL = ROOT.join("install.sh")
UNINSTALL = ROOT.join("uninstall.sh")
ROLLBACK = ROOT.join("rollback.sh")

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

def run_cmd_capture(env, *args, stdin_data: nil, chdir: nil)
  opts = {}
  opts[:stdin_data] = stdin_data if stdin_data
  opts[:chdir] = chdir.to_s if chdir
  stdout, stderr, status = Open3.capture3(env, *args.map(&:to_s), opts)
  [status.exitstatus, stdout, stderr]
end

def run_ruby(*args)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, *args.map(&:to_s))
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

def assert_hash_valid(name, path, field)
  record = read_json(path)
  assert(name, record[field] == hash_record(record, field), "#{path}: #{field} mismatch")
  record
end

def assert_file_record_hashes(name, records)
  records.each do |record|
    path = Pathname.new(record.fetch("path"))
    expected = path.file? ? Digest::SHA256.file(path).hexdigest : "0" * 64
    assert(name, record.fetch("content_sha256") == expected, "#{path}: stale file record hash")
  end
end

def assert_global_ledger_valid(name, state_root)
  path = state_root.join("trusted-state-ledger-global.jsonl")
  assert(name, path.file?, "global ledger was not written")
  errors = StrictModeGlobalLedger.validate_chain(path)
  assert(name, errors.empty?, "global ledger chain invalid", errors.join("\n"))
  StrictModeGlobalLedger.load_records(path)
end

def assert_ledger_has(name, records, writer, target_class)
  assert(
    name,
    records.any? { |record| record.fetch("writer") == writer && record.fetch("target_class") == target_class },
    "missing #{writer} #{target_class} ledger record"
  )
end

def corrupt_global_ledger!(state_root)
  path = state_root.join("trusted-state-ledger-global.jsonl")
  lines = path.read.lines
  record = JSON.parse(lines.fetch(0))
  record["writer"] = "repair"
  lines[0] = JSON.generate(record) + "\n"
  path.write(lines.join)
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
    "content_sha256" => exists == 1 ? Digest::SHA256.file(path).hexdigest : "0" * 64
  }
end

def protected_file_inode_index(records)
  records.flatten.each_with_object({}) do |record, index|
    next unless record.fetch("exists", 0) == 1
    next if record.fetch("dev", 0).to_i.zero? || record.fetch("inode", 0).to_i.zero?

    key = "#{record.fetch("dev")}:#{record.fetch("inode")}"
    index[key] ||= []
    index[key] << {
      "dev" => record.fetch("dev"),
      "inode" => record.fetch("inode"),
      "path" => record.fetch("path"),
      "kind" => record.fetch("kind"),
      "provider" => record.fetch("provider", ""),
      "content_sha256" => record.fetch("content_sha256")
    }
  end.each_with_object({}) do |(key, entries), sorted|
    sorted[key] = entries.uniq.sort_by { |entry| [entry.fetch("path"), entry.fetch("kind"), entry.fetch("provider")] }
  end
end

def replace_file_record!(records, replacement)
  index = records.index { |record| record.fetch("path") == replacement.fetch("path") && record.fetch("kind") == replacement.fetch("kind") }
  raise "record not found for #{replacement.fetch("path")}" unless index

  records[index] = replacement
end

def assert_sorted_unique_file_records(name, records, label)
  keys = records.map { |record| [record.fetch("path"), record.fetch("kind")] }
  assert(name, keys == keys.sort, "#{label} file records are not sorted by path/kind")
  assert(name, keys == keys.uniq, "#{label} file records contain duplicate path/kind entries")
end

def assert_managed_hook_entries(name, entries)
  errors = StrictModeHookEntryPlan.validate(entries, selected_output_contracts: [], enforce: false)
  assert(name, errors.empty?, "managed hook entries failed validation", errors.join("\n"))
  expected_selector_fields = %w[
    provider
    config_path
    hook_event
    matcher
    command
    provider_env_hash
    self_timeout_ms
    provider_timeout_ms
    provider_timeout_field
    output_contract_id
    entry_hash
  ]
  assert(name, entries.all? { |entry| entry["provider_version"] == "unknown" }, "managed entries must bind provider_version")
  assert(name, entries.all? { |entry| entry["config_path"].to_s.start_with?("/") }, "managed entries must bind config_path")
  assert(name, entries.all? { |entry| entry.fetch("removal_selector").keys.sort == expected_selector_fields.sort }, "removal selector fields mismatch")
end

def runtime_settings(path)
  path.read.lines.each_with_object({}) do |line, settings|
    text = line.strip
    next if text.empty? || text.start_with?("#")

    key, value = text.split("=", 2)
    settings[key] = value
  end
end

def write_runtime_env(install_root, bytes)
  path = install_root.join("config/runtime.env")
  path.dirname.mkpath
  path.write(bytes)
end

def with_fixture
  $cases += 1
  Dir.mktmpdir("strict-installer-") do |dir|
    root = Pathname.new(dir)
    home = root.join("home")
    install_root = root.join("strict root")
    home.join(".claude").mkpath
    home.join(".codex").mkpath
    home.join(".claude/settings.json").write(JSON.pretty_generate({
      "hooks" => {
        "Stop" => [
          { "hooks" => [{ "type" => "command", "command" => "echo keep-claude" }] }
        ]
      }
    }) + "\n")
    home.join(".codex/hooks.json").write(JSON.pretty_generate({
      "hooks" => {
        "Stop" => [
          { "hooks" => [{ "type" => "command", "command" => "echo keep-codex" }] }
        ]
      }
    }) + "\n")
    home.join(".codex/config.toml").write("[features]\nexisting = true\n")
    yield root, home, install_root
  end
end

def strict_commands(config)
  config.fetch("hooks").values.flatten.flat_map { |entry| entry.fetch("hooks", []) }.
    map { |hook| hook["command"] }.
    compact.
    select { |command| command.include?("active/bin/strict-hook") }
end

def selected_output_contract(provider, logical_event, contract_id)
  {
    "provider" => provider,
    "provider_version" => "unknown",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => logical_event,
    "logical_event" => logical_event,
    "contract_kind" => "decision-output",
    "contract_id" => contract_id,
    "provider_action" => "block",
    "decision_contract_hash" => "a" * 64,
    "fixture_record_hash" => "b" * 64,
    "fixture_manifest_hash" => "c" * 64
  }
end

def copy_project_root(destination)
  destination.mkpath
  ROOT.children.each do |child|
    FileUtils.cp_r(child, destination.join(child.basename.to_s))
  end
  destination
end

def fixture_file(root, provider, relative_name, content)
  path = root.join("providers/#{provider}/fixtures/#{relative_name}")
  path.dirname.mkpath
  path.write(content)
  path
end

def fixture_hash_entry(root, path)
  {
    "path" => path.relative_path_from(root).to_s,
    "content_sha256" => Digest::SHA256.file(path).hexdigest
  }
end

def compatibility_range_for(provider_version, provider_build_hash = "")
  if provider_version == "unknown"
    {
      "mode" => "unknown-only",
      "min_version" => "unknown",
      "max_version" => "unknown",
      "version_comparator" => "",
      "provider_build_hashes" => []
    }
  else
    {
      "mode" => "exact",
      "min_version" => provider_version,
      "max_version" => provider_version,
      "version_comparator" => "",
      "provider_build_hashes" => provider_build_hash.empty? ? [] : [provider_build_hash]
    }
  end
end

def typed_contract_proof(provider:, contract_kind:, event:, contract_id:, provider_version: "unknown", provider_build_hash: "")
  payload_hash = Digest::SHA256.hexdigest("#{provider}:#{event}:payload")
  case contract_kind
  when "command-execution"
    {
      "schema_version" => 1,
      "proof_kind" => "#{provider}.command-execution.observed",
      "provider" => provider,
      "provider_version" => provider_version,
      "provider_build_hash" => provider_build_hash,
      "event" => event,
      "contract_id" => contract_id,
      "hook_command_executed" => true,
      "hook_argv" => ["strict-hook", "--provider", provider, event],
      "hook_exit_status" => 0,
      "stdout_sha256" => Digest::SHA256.hexdigest(""),
      "stderr_sha256" => Digest::SHA256.hexdigest(""),
      "discovery_recorded_at" => "2026-05-06T00:00:00Z",
      "provider_detection_decision" => "match",
      "payload_sha256" => payload_hash,
      "raw_payload_captured" => true,
      "raw_payload_path" => "/tmp/#{payload_hash[0, 12]}.payload",
      "hook_mode" => "discovery-log-only"
    }
  when "event-order"
    {
      "schema_version" => 1,
      "proof_kind" => "#{provider}.event-order.observed",
      "provider" => provider,
      "provider_version" => provider_version,
      "provider_build_hash" => provider_build_hash,
      "event" => event,
      "contract_id" => contract_id,
      "early_baseline_events_before_tool" => true,
      "observed_order" => [
        { "event" => event, "recorded_at" => "2026-05-06T00:00:00Z", "payload_sha256" => payload_hash },
        { "event" => "pre-tool-use", "recorded_at" => "2026-05-06T00:00:01Z", "payload_sha256" => Digest::SHA256.hexdigest("#{provider}:pre") }
      ]
    }
  when "matcher"
    {
      "schema_version" => 1,
      "proof_kind" => "#{provider}.matcher.observed",
      "provider" => provider,
      "provider_version" => provider_version,
      "provider_build_hash" => provider_build_hash,
      "event" => event,
      "contract_id" => contract_id,
      "matcher" => ".*",
      "matched_tool_event" => true,
      "provider_detection_decision" => "match",
      "payload_sha256" => payload_hash,
      "raw_payload_path" => "/tmp/#{payload_hash[0, 12]}.payload",
      "preflight_trusted" => true,
      "tool_kind" => "shell"
    }
  else
    { "schema_version" => 1, "contract_id" => contract_id }
  end
end

def raw_payload_hash_for(root, provider, event)
  event_dir = root.join("providers/#{provider}/fixtures/payloads/#{event}")
  if event_dir.directory?
    raw = event_dir.children.select { |path| path.file? && path.extname == ".json" }.sort.first
    return Digest::SHA256.file(raw).hexdigest if raw
  end
  body = JSON.generate({ "event" => event, "thread_id" => "t1" }) + "\n"
  hash = Digest::SHA256.hexdigest(body)
  fixture_file(root, provider, "payloads/#{event}/#{hash[0, 16]}.json", body)
  hash
end

def provider_proof_hash_for(root, provider, event, payload_hash)
  proof_dir = root.join("providers/#{provider}/fixtures/provider-proof/#{event}")
  if proof_dir.directory?
    proof_dir.children.sort.each do |path|
      next unless path.file? && path.basename.to_s.end_with?(".provider-detection.json")

      proof = JSON.parse(path.read)
      return proof.fetch("provider_proof_hash") if proof["payload_sha256"] == payload_hash && proof["decision"] == "match"
    end
  end
  proof = {
    "schema_version" => 1,
    "provider_arg" => provider,
    "provider_arg_source" => "fixture-import",
    "payload_sha256" => payload_hash,
    "detected_provider" => provider,
    "decision" => "match",
    "claude_indicators" => [],
    "codex_indicators" => [],
    "conflict_indicators" => [],
    "fixture_usable" => true,
    "enforcement_usable" => false,
    "diagnostic" => "test provider proof",
    "provider_proof_hash" => ""
  }
  proof["provider_proof_hash"] = StrictModeMetadata.hash_record(proof, "provider_proof_hash")
  fixture_file(root, provider, "provider-proof/#{event}/#{payload_hash[0, 16]}.provider-detection.json", JSON.pretty_generate(proof) + "\n")
  proof.fetch("provider_proof_hash")
end

def bind_proof_to_raw_payload!(root, provider, proof)
  event = proof.fetch("event")
  hash = raw_payload_hash_for(root, provider, event)
  provider_proof_hash = provider_proof_hash_for(root, provider, event, hash)
  case proof.fetch("proof_kind")
  when "#{provider}.command-execution.observed", "#{provider}.matcher.observed"
    proof["payload_sha256"] = hash
    proof["raw_payload_path"] = "/captures/#{hash[0, 12]}.payload"
  when "#{provider}.event-order.observed"
    proof.fetch("observed_order").each do |item|
      item["payload_sha256"] = raw_payload_hash_for(root, provider, item.fetch("event"))
    end
  end
  proof
end

def discovery_record_for(proof, event, provider_proof_hash: "0" * 64)
  {
    "schema_version" => 1,
    "recorded_at" => proof["discovery_recorded_at"] || "2026-05-06T00:00:00Z",
    "provider" => proof.fetch("provider"),
    "event" => event,
    "mode" => proof["hook_mode"] || "discovery-log-only",
    "provider_detection_decision" => proof.fetch("provider_detection_decision", "match"),
    "provider_proof_hash" => provider_proof_hash,
    "payload_sha256" => proof.fetch("payload_sha256"),
    "raw_payload_captured" => proof.fetch("raw_payload_captured", true),
    "raw_payload_path" => proof.fetch("raw_payload_path", "/captures/#{proof.fetch("payload_sha256")[0, 12]}.payload")
  }
end

def fixture_record(root, provider:, contract_id:, contract_kind:, event:, provider_version: "unknown", provider_build_hash: "")
  fixture_paths = if StrictModeFixtures.typed_generic_contract_kind?(contract_kind)
                    proof = typed_contract_proof(
                      provider: provider,
                      contract_kind: contract_kind,
                      event: event,
                      contract_id: contract_id,
                      provider_version: provider_version,
                      provider_build_hash: provider_build_hash
                    )
                    bind_proof_to_raw_payload!(root, provider, proof)
                    proof_path = fixture_file(root, provider, "#{contract_kind}/#{event}/#{contract_id}.#{contract_kind}.json", JSON.pretty_generate(proof) + "\n")
                    paths = [proof_path]
                    case contract_kind
                    when "command-execution"
                      provider_hash = provider_proof_hash_for(root, provider, event, proof.fetch("payload_sha256"))
                      discovery_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.discovery-record.json", JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_hash)) + "\n")
                      stdout_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.stdout", "")
                      stderr_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.stderr", "")
                      exit_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.exit-code", "#{proof.fetch("hook_exit_status")}\n")
                      paths.concat([discovery_path, stdout_path, stderr_path, exit_path])
                    when "matcher"
                      provider_hash = provider_proof_hash_for(root, provider, event, proof.fetch("payload_sha256"))
                      paths << fixture_file(root, provider, "matcher/#{event}/#{contract_id}.discovery-record.json", JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_hash)) + "\n")
                    when "event-order"
                      proof.fetch("observed_order").each_with_index do |item, index|
                        command_like = {
                          "provider" => provider,
                          "payload_sha256" => item.fetch("payload_sha256"),
                          "raw_payload_path" => "/captures/#{item.fetch("payload_sha256")[0, 12]}.payload",
                          "raw_payload_captured" => true,
                          "hook_mode" => "discovery-log-only",
                          "provider_detection_decision" => "match",
                          "provider_proof_hash" => provider_proof_hash_for(root, provider, item.fetch("event"), item.fetch("payload_sha256")),
                          "discovery_recorded_at" => item.fetch("recorded_at")
                        }
                        paths << fixture_file(root, provider, "event-order/#{event}/#{contract_id}.#{index + 1}-#{item.fetch("event")}.discovery-record.json", JSON.pretty_generate(discovery_record_for(command_like, item.fetch("event"), provider_proof_hash: command_like.fetch("provider_proof_hash"))) + "\n")
                      end
                    end
                    paths
                  else
                    [fixture_file(root, provider, "#{contract_kind}/#{event}/#{contract_id}.txt", "#{contract_id}\n")]
                  end
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => provider_version,
    "provider_build_hash" => provider_build_hash,
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => contract_kind,
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => fixture_paths.map { |fixture| fixture_hash_entry(root, fixture) }.sort_by { |entry| entry.fetch("path") },
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => compatibility_range_for(provider_version, provider_build_hash),
    "fixture_record_hash" => ""
  }
  if contract_kind == "command-execution"
    proof = StrictModeFixtures.load_typed_contract_proof(fixture_paths.first)
    record["command_execution_contract_hash"] = StrictModeFixtures.typed_contract_proof_hash(record, proof)
  end
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def decision_output_fixture_record(root, provider:, contract_id:, event:, provider_action: "block", provider_version: "unknown", provider_build_hash: "")
  action = provider_action == "deny" ? "deny" : "block"
  metadata = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "event" => event,
    "logical_event" => event,
    "provider_action" => provider_action,
    "stdout_mode" => "json",
    "stdout_required_fields" => %w[decision reason],
    "stderr_mode" => "empty",
    "stderr_required_fields" => [],
    "exit_code" => 0,
    "blocks_or_denies" => 1,
    "injects_context" => 0,
    "decision_contract_hash" => ""
  }
  metadata["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(metadata)
  metadata_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.provider-output.json", JSON.pretty_generate(metadata) + "\n")
  stdout_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.stdout", JSON.generate({ "decision" => action, "reason" => "blocked" }) + "\n")
  stderr_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.stderr", "")
  exit_code_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.exit-code", "0\n")
  record = fixture_record(root, provider: provider, contract_id: contract_id, contract_kind: "decision-output", event: event, provider_version: provider_version, provider_build_hash: provider_build_hash)
  record["decision_contract_hash"] = metadata.fetch("decision_contract_hash")
  record["fixture_file_hashes"] = [metadata_path, stdout_path, stderr_path, exit_code_path].map { |path| fixture_hash_entry(root, path) }.sort_by { |entry| entry.fetch("path") }
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def write_fixture_manifest(root, provider, records)
  StrictModeFixtures.write_manifest(StrictModeFixtures.manifest_path(root, provider), {
    "schema_version" => 1,
    "generated_at" => "2026-05-06T00:00:00Z",
    "records" => records,
    "manifest_hash" => ""
  })
  errors = StrictModeFixtures.validate_provider_manifest(root, provider)
  raise errors.join("\n") unless errors.empty?
end

def import_payload_fixture(root, provider, event, provider_version: "unknown", provider_build_hash: "")
  source = root.join("capture/#{provider}-#{event}.json")
  source.dirname.mkpath
  source.write(JSON.generate({
    "event" => event,
    "thread_id" => "t1",
    "tool_name" => event == "pre-tool-use" ? "apply_patch" : nil,
    "tool_input" => event == "pre-tool-use" ? { "patch" => "*** Begin Patch\n*** Add File: lib/#{event}.rb\n+puts 1\n*** End Patch\n" } : nil
  }.compact) + "\n")
  project = root.join("fixture-project")
  cwd = project.join("src")
  cwd.mkpath
  args = [
    root.join("tools/import-discovery-fixture.rb"),
    "--root", root,
    "--provider", provider,
    "--event", event,
    "--source", source,
    "--cwd", cwd,
    "--project-dir", project,
    "--provider-version", provider_version,
    "--captured-at", "2026-05-06T00:00:00Z"
  ]
  args.concat(["--provider-build-hash", provider_build_hash]) unless provider_build_hash.empty?
  run_ruby(*args)
end

def copied_project_with_codex_enforcing_fixtures(root, provider_version: "unknown", provider_build_hash: "")
  project_root = copy_project_root(root.join("project-root"))
  fixture_root = project_root.join("providers/codex/fixtures")
  fixture_root.children.each { |child| FileUtils.rm_rf(child) unless child.basename.to_s == "README.md" }
  StrictModeFixtures.write_manifest(StrictModeFixtures.manifest_path(project_root, "codex"), StrictModeFixtures.empty_manifest("2026-05-06T00:00:00Z"))
  payload_records = []
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    status, output = import_payload_fixture(project_root, "codex", event, provider_version: provider_version, provider_build_hash: provider_build_hash)
    raise output unless status.zero?

    payload_records = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(project_root, "codex")).fetch("records")
  end
  records = payload_records + [
    fixture_record(project_root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start", provider_version: provider_version, provider_build_hash: provider_build_hash),
    fixture_record(project_root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use", provider_version: provider_version, provider_build_hash: provider_build_hash)
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << fixture_record(project_root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event, provider_version: provider_version, provider_build_hash: provider_build_hash)
  end
  records << decision_output_fixture_record(project_root, provider: "codex", contract_id: "codex.pre-tool-use.block", event: "pre-tool-use", provider_version: provider_version, provider_build_hash: provider_build_hash)
  records << decision_output_fixture_record(project_root, provider: "codex", contract_id: "codex.stop.block", event: "stop", provider_version: provider_version, provider_build_hash: provider_build_hash)
  write_fixture_manifest(project_root, "codex", records)
  project_root
end

with_fixture do |_root, _home, install_root|
  name = "global lock writes exact owner record and releases cleanly"
  lock = nil
  begin
    lock = StrictModeGlobalLock.acquire!(install_root, state_root: install_root.join("state"), transaction_kind: "install")
    lock_dir = install_root.join("state-global.lock")
    owner_path = lock_dir.join("owner.json")
    owner = assert_hash_valid(name, owner_path, "owner_hash")
    owner_status = StrictModeGlobalLock.load_owner(owner_path, expected_scope: "global")
    assert(name, owner_status.fetch("trusted") == true, "lock owner parser rejected generated owner", owner_status.fetch("errors").join("\n"))
    assert(name, owner_status.fetch("stale_candidate") == false, "fresh lock owner marked stale")
    assert(name, owner.keys.sort == StrictModeGlobalLock::OWNER_FIELDS.sort, "lock owner fields mismatch")
    assert(name, owner.fetch("schema_version") == 1, "lock owner schema_version mismatch")
    assert(name, owner.fetch("lock_scope") == "global", "lock owner scope mismatch")
    assert(name, owner.fetch("transaction_kind") == "install", "lock owner transaction_kind mismatch")
    assert(name, %w[provider session_key raw_session_hash cwd project_dir].all? { |field| owner.fetch(field) == "" }, "global lock owner should use empty session tuple")
    assert(name, owner.fetch("pid").is_a?(Integer) && owner.fetch("pid") >= 0, "lock owner pid invalid")
    assert(name, (owner_path.stat.mode & 0o777) == 0o600, "lock owner mode must be 0600")

    extra = JSON.parse(JSON.generate(owner))
    extra["unexpected"] = true
    assert(name, StrictModeGlobalLock.validate_owner(extra).any? { |error| error.include?("fields mismatch") }, "lock owner validator accepted extra fields")

    drifted = JSON.parse(JSON.generate(owner))
    drifted["pid"] += 1
    assert(name, StrictModeGlobalLock.validate_owner(drifted).include?("owner_hash mismatch"), "lock owner validator accepted hash drift")

    populated_global_tuple = JSON.parse(JSON.generate(owner))
    populated_global_tuple["provider"] = "claude"
    populated_global_tuple["owner_hash"] = hash_record(populated_global_tuple, "owner_hash")
    assert(name, StrictModeGlobalLock.validate_owner(populated_global_tuple).include?("provider must be empty for global lock"), "lock owner validator accepted populated global tuple")

    empty_session_tuple = JSON.parse(JSON.generate(owner))
    empty_session_tuple["lock_scope"] = "session"
    empty_session_tuple["owner_hash"] = hash_record(empty_session_tuple, "owner_hash")
    assert(name, StrictModeGlobalLock.validate_owner(empty_session_tuple).include?("provider must be non-empty for session lock"), "lock owner validator accepted empty session tuple")

    expired = JSON.parse(JSON.generate(owner))
    expired["created_at"] = (Time.now.utc - 7200).iso8601
    expired["timeout_at"] = (Time.now.utc - 3600).iso8601
    expired["owner_hash"] = hash_record(expired, "owner_hash")
    assert(name, StrictModeGlobalLock.stale_candidate?(expired), "expired lock owner was not marked as stale candidate")
    assert(name, lock_dir.exist?, "stale-candidate validation must not remove the lock")
  ensure
    lock.release if lock
  end
  assert(name, !install_root.join("state-global.lock").exist?, "global lock directory was not released")
end

with_fixture do |_root, home, install_root|
  name = "install refuses occupied global lock before provider mutation"
  install_root.join("state-global.lock").mkpath
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, output.include?("state-global.lock") && output.include?("another global transaction is active"), "missing global lock diagnostic", output)
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "install mutated Claude hooks while global lock was held")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).empty?, "install mutated Codex hooks while global lock was held")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "locked install created pending marker")
end

with_fixture do |_root, home, install_root|
  name = "install all creates discovery runtime and hash-bound metadata"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  active = install_root.join("active")
  assert(name, File.symlink?(active), "active runtime is not a symlink")
  assert(name, active.join("bin/strict-hook").file? && active.join("bin/strict-hook").executable?, "active strict-hook missing or not executable")
  assert(name, active.join("tools/provider_detection_lib.rb").file?, "active provider detection runtime helper missing")
  assert(name, active.join("schemas/schema-registry.json").file?, "schema metadata was not copied into active runtime")
  assert(name, active.join("matrices/matrix-registry.json").file?, "matrix metadata was not copied into active runtime")

  manifest = assert_hash_valid(name, install_root.join("install-manifest.json"), "manifest_hash")
  baseline = assert_hash_valid(name, install_root.join("state/protected-install-baseline.json"), "baseline_hash")
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  %w[
    install-release
    active-runtime-link
    provider-config
    runtime-config
    protected-config
    install-manifest
    protected-install-baseline
    installer-backup
    installer-marker
  ].each do |target_class|
    assert_ledger_has(name, ledger, "install", target_class)
  end
  drifted_ledger = JSON.parse(JSON.generate(ledger.first))
  drifted_ledger["target_class"] = "baseline"
  drifted_ledger["record_hash"] = hash_record(drifted_ledger, "record_hash")
  assert(name, StrictModeGlobalLedger.validate_record(drifted_ledger).include?("target_class invalid"), "ledger validator accepted invalid global target class")
  populated_tuple_ledger = JSON.parse(JSON.generate(ledger.first))
  populated_tuple_ledger["provider"] = "claude"
  populated_tuple_ledger["record_hash"] = hash_record(populated_tuple_ledger, "record_hash")
  assert(name, StrictModeGlobalLedger.validate_record(populated_tuple_ledger).include?("provider must be empty for global install ledger"), "ledger validator accepted populated global tuple")
  malformed_fingerprint_ledger = JSON.parse(JSON.generate(ledger.first))
  malformed_fingerprint_ledger.fetch("old_fingerprint")["unexpected"] = true
  malformed_fingerprint_ledger["record_hash"] = hash_record(malformed_fingerprint_ledger, "record_hash")
  assert(name, StrictModeGlobalLedger.validate_record(malformed_fingerprint_ledger).any? { |error| error.include?("fingerprint fields mismatch") }, "ledger validator accepted malformed fingerprint")
  operation_drift_ledger = JSON.parse(JSON.generate(ledger.first))
  operation_drift_ledger["operation"] = operation_drift_ledger.fetch("operation") == "create" ? "modify" : "create"
  operation_drift_ledger["record_hash"] = hash_record(operation_drift_ledger, "record_hash")
  assert(name, StrictModeGlobalLedger.validate_record(operation_drift_ledger).include?("operation does not match old/new fingerprints"), "ledger validator accepted operation/fingerprint drift")
  bad_active_target = JSON.parse(JSON.generate(ledger.find { |record| record.fetch("target_class") == "active-runtime-link" }))
  bad_active_target["target_path"] = install_root.join("not-active").to_s
  bad_active_target["record_hash"] = hash_record(bad_active_target, "record_hash")
  assert(name, StrictModeGlobalLedger.validate_record(bad_active_target).include?("active-runtime-link target_path must end with /active"), "ledger validator accepted non-lexical active runtime target")
  complete_markers = Dir[install_root.join("install-transactions/*.complete.json")]
  pending_markers = Dir[install_root.join("install-transactions/*.pending.json")]
  assert(name, pending_markers.empty?, "successful install left pending transaction markers")
  assert(name, complete_markers.size == 1, "successful install did not publish exactly one complete marker")
  assert(name, assert_hash_valid(name, Pathname.new(complete_markers.fetch(0)), "marker_hash").fetch("phase") == "complete", "install complete marker phase mismatch")
  entries = manifest.fetch("managed_hook_entries")
  assert(name, entries.size == 10, "expected 10 managed discovery hooks, got #{entries.size}")
  assert(name, baseline.fetch("managed_hook_entries").size == 10, "baseline managed hook count mismatch")
  assert_managed_hook_entries(name, entries)
  assert_managed_hook_entries(name, baseline.fetch("managed_hook_entries"))
  assert(name, manifest.fetch("selected_output_contracts") == [], "discovery manifest must not select output contracts")
  assert(name, baseline.fetch("selected_output_contracts") == [], "discovery baseline must not select output contracts")
  assert(name, entries.all? { |entry| entry["enforcing"] == false && entry["output_contract_id"] == "" }, "discovery hooks must not claim enforcement")
  assert(name, entries.all? { |entry| entry["command"].include?("\"#{install_root}/active/bin/strict-hook\"") }, "commands do not use quoted lexical active hook path")
  assert(name, entries.all? { |entry| entry["command"].include?("STRICT_STATE_ROOT=\"#{install_root}/state\"") }, "commands do not bind state root")
  assert(name, entries.none? { |entry| entry["command"].include?("/releases/") }, "commands must not point at release realpath")
  assert(name, entries.all? { |entry| entry["command"].include?("--provider #{entry.fetch("provider")}") }, "commands must pass provider argv")
  provider_config_paths = manifest.fetch("provider_config_records").map { |record| record.fetch("path") }
  assert(name, provider_config_paths.include?(home.join(".codex/config.toml").to_s), "Codex feature-flag config was not covered by provider_config_records")
  assert(name, baseline.fetch("provider_config_paths") == provider_config_paths.sort, "baseline provider_config_paths do not match provider_config_records")
  assert_file_record_hashes(name, manifest.fetch("provider_config_records"))
  %w[
    runtime_file_records
    runtime_config_records
    provider_config_records
    protected_config_records
  ].each do |field|
    assert_sorted_unique_file_records(name, manifest.fetch(field), "manifest #{field}")
    assert_sorted_unique_file_records(name, baseline.fetch(field), "baseline #{field}")
  end
  runtime_env = install_root.join("config/runtime.env")
  runtime = runtime_settings(runtime_env)
  assert(name, runtime.fetch("STRICT_NO_CLAUDE_WORKER") == "1", "installed runtime.env enables Claude worker before fixture proof")
  assert(name, baseline.fetch("generated_hook_env") == {
    "STRICT_HOOK_TIMEOUT_MS" => "per-hook command prefix",
    "STRICT_ENFORCING_HOOK" => "per-enforcing hook command prefix",
    "STRICT_OUTPUT_CONTRACT_ID" => "per-enforcing hook command prefix",
    "STRICT_STATE_ROOT" => "per-install command prefix"
  }, "baseline generated hook env mismatch")
  assert(name, runtime.fetch("STRICT_NO_CODEX_WORKER") == "1", "installed runtime.env enables Codex worker before fixture proof")
  assert(name, manifest.fetch("runtime_config_records").any? { |record| record.fetch("path") == runtime_env.to_s && record.fetch("content_sha256") == Digest::SHA256.file(runtime_env).hexdigest }, "runtime.env worker defaults are not manifest-covered")

  claude = read_json(home.join(".claude/settings.json"))
  codex = read_json(home.join(".codex/hooks.json"))
  assert(name, !claude.fetch("hooks").key?("SubagentStop"), "Claude SubagentStop installed without fixture proof")
  assert(name, !codex.fetch("hooks").key?("PermissionRequest"), "Codex PermissionRequest installed without fixture proof")
  assert(name, home.join(".codex/config.toml").read.include?("existing = true"), "Codex TOML merge lost existing feature")
  assert(name, home.join(".codex/config.toml").read.include?("codex_hooks = true"), "Codex hooks feature not enabled")
end

with_fixture do |root, home, install_root|
  name = "custom state root hook command trusts external baseline"
  state_root = root.join("external state")
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root, "--state-root", state_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "expected custom state-root install success, got #{exitstatus}", output)
  manifest = assert_hash_valid(name, install_root.join("install-manifest.json"), "manifest_hash")
  baseline = assert_hash_valid(name, state_root.join("protected-install-baseline.json"), "baseline_hash")
  assert(name, manifest.fetch("state_root") == state_root.to_s, "manifest state_root mismatch")
  assert(name, baseline.fetch("state_root") == state_root.to_s, "baseline state_root mismatch")
  commands = strict_commands(read_json(home.join(".codex/hooks.json")))
  assert(name, commands.all? { |command| command.include?("STRICT_STATE_ROOT=\"#{state_root}\"") }, "provider commands do not bind external state root", commands.join("\n"))

  project = root.join("project")
  project.mkpath
  command = commands.find { |candidate| candidate.include?(" pre-tool-use") }
  unless command
    record_failure(name, "missing managed pre-tool-use command", commands.join("\n"))
    next
  end
  payload = {
    "hook_event_name" => "PreToolUse",
    "session_id" => "s1",
    "transcript_path" => home.join(".codex/sessions/s1.jsonl").to_s,
    "turn_id" => "t1",
    "cwd" => project.to_s,
    "model" => "gpt-5.3-codex-spark",
    "tool_name" => "Bash",
    "tool_input" => {
      "command" => "printf custom-state"
    }
  }
  status, stdout, stderr = run_cmd_capture({ "HOME" => home.to_s }, "/bin/sh", "-c", command, stdin_data: JSON.generate(payload) + "\n", chdir: project)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "strict hook command failed", stdout + stderr)
  record = JSON.parse(state_root.join("discovery/codex-pre-tool-use.jsonl").read.lines.last)
  assert(name, record.fetch("provider_detection_decision") == "match", "custom state-root hook did not trust Codex provider", record.inspect)
  assert(name, record.fetch("preflight").fetch("trusted") == true, "custom state-root hook did not trust protected baseline", record.inspect)
  assert(name, record.fetch("preflight").fetch("reason_code") == "shell-read-only-or-unmatched", "custom state-root hook classified unexpected preflight", record.inspect)
end

with_fixture do |_root, home, install_root|
  name = "reinstall is idempotent and preserves unrelated hooks"
  2.times do
    exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
    assert_no_stacktrace(name, output)
    assert(name, exitstatus.zero?, "install failed", output)
  end

  claude = read_json(home.join(".claude/settings.json"))
  codex = read_json(home.join(".codex/hooks.json"))
  assert(name, strict_commands(claude).size == 5, "Claude strict hook entries duplicated")
  assert(name, strict_commands(codex).size == 5, "Codex strict hook entries duplicated")
  assert(name, claude.fetch("hooks").fetch("Stop").any? { |entry| entry.fetch("hooks").any? { |hook| hook["command"] == "echo keep-claude" } }, "Claude unrelated hook was not preserved")
  assert(name, codex.fetch("hooks").fetch("Stop").any? { |entry| entry.fetch("hooks").any? { |hook| hook["command"] == "echo keep-codex" } }, "Codex unrelated hook was not preserved")
end

with_fixture do |_root, home, install_root|
  name = "reinstall removes legacy managed commands after command shape upgrade"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "initial install failed", output)

  config_path = home.join(".codex/hooks.json")
  config = read_json(config_path)
  config.fetch("hooks").each_value do |entries|
    legacy_entries = entries.map do |entry|
      legacy = JSON.parse(JSON.generate(entry))
      legacy.fetch("hooks").each do |hook|
        hook["command"] = hook.fetch("command").sub(/ STRICT_STATE_ROOT="[^"]+"/, "")
      end
      legacy
    end
    entries.unshift(*legacy_entries)
  end
  config_path.write(JSON.pretty_generate(config) + "\n")
  assert(name, strict_commands(read_json(config_path)).size == 10, "setup did not create legacy duplicate commands")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall failed", output)
  commands = strict_commands(read_json(config_path))
  assert(name, commands.size == 5, "reinstall left legacy managed hook duplicates", commands.join("\n"))
  assert(name, commands.all? { |command| command.include?("STRICT_STATE_ROOT=\"#{install_root}/state\"") }, "reinstall left command without state-root binding", commands.join("\n"))
end

with_fixture do |_root, home, install_root|
  name = "install cleans completed pending marker before reinstall"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_INSTALL_COMPLETE_MARKER" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after install complete marker publication"), "missing install complete-marker interruption diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_before = complete_path.read
  assert(name, read_json(pending_path).fetch("phase") == "activating", "interrupted install did not leave activating pending marker")
  assert_hash_valid(name, complete_path, "marker_hash")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_before = ledger_before.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_before.size == 1, "interrupted install did not ledger exactly one complete-marker create")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after completed-pending cleanup failed", output)
  assert(name, !pending_path.exist?, "reinstall did not clean old completed pending marker")
  assert(name, complete_path.read == complete_before, "reinstall rewrote old complete marker")
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_after = ledger_after.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_after.size == 1, "reinstall wrote duplicate complete-marker create for old transaction")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "reinstall left pending markers")
  assert(name, Dir[install_root.join("install-transactions/*.complete.json")].size == 2, "reinstall did not publish its own complete marker")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "reinstall did not leave Claude hooks active")
end

with_fixture do |_root, home, install_root|
  name = "install ledgers existing complete marker after write interruption"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_COMPLETE_MARKER_WRITE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after complete marker write before ledger append"), "missing complete-marker write interruption diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_before = complete_path.read
  assert(name, read_json(pending_path).fetch("phase") == "activating", "write-interrupted install did not leave activating pending marker")
  assert_hash_valid(name, complete_path, "marker_hash")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_before = ledger_before.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_before.empty?, "complete-marker write interruption already had a complete-marker create")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after complete-marker ledger repair failed", output)
  assert(name, !pending_path.exist?, "reinstall did not clean write-interrupted pending marker")
  assert(name, complete_path.read == complete_before, "reinstall rewrote write-interrupted complete marker")
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_after = ledger_after.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_after.size == 1, "reinstall did not repair exactly one complete-marker create")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "reinstall left pending markers after ledger repair")
end

with_fixture do |_root, home, install_root|
  name = "install repairs pending delete ledger after delete interruption"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PENDING_MARKER_DELETE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after pending marker delete before ledger append"), "missing pending-delete interruption diagnostic", output)
  pending_path = install_root.join("install-transactions").children.find { |path| path.basename.to_s.end_with?(".pending.json") }
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  transaction_id = read_json(complete_path).fetch("transaction_id")
  pending_path = install_root.join("install-transactions/#{transaction_id}.pending.json") unless pending_path
  assert(name, !pending_path.exist?, "pending-delete interruption left pending marker")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_before = ledger_before.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_before.empty?, "pending-delete interruption already had pending delete ledger")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after pending delete repair failed", output)
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_after = ledger_after.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_after.size == 1, "reinstall did not repair exactly one pending delete ledger")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "pending delete repair left pending markers")
end

with_fixture do |_root, home, install_root|
  name = "install refuses missing pending delete preimage"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_REMOVE_PENDING_BEFORE_PENDING_MARKER_DELETE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected missing-preimage install failure, got #{exitstatus}", output)
  assert(name, output.include?("pending marker delete preimage missing"), "missing pending-delete preimage diagnostic", output)
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  transaction_id = read_json(complete_path).fetch("transaction_id")
  pending_path = install_root.join("install-transactions/#{transaction_id}.pending.json")
  assert(name, !pending_path.exist?, "missing-preimage failure left pending marker")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_before = ledger_before.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_before.empty?, "missing-preimage failure wrote pending delete ledger")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after missing-preimage repair failed", output)
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_after = ledger_after.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_after.size == 1, "reinstall did not repair missing-preimage pending delete ledger")
end

with_fixture do |_root, home, install_root|
  name = "install refuses cross-writer pending delete ledger"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PENDING_MARKER_DELETE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_marker = read_json(complete_path)
  pending_path = install_root.join("install-transactions/#{complete_marker.fetch("transaction_id")}.pending.json")
  state_root = install_root.join("state")
  ledger_before = assert_global_ledger_valid(name, state_root)
  pending_preimage = ledger_before.reverse.find do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") != "delete" &&
      record.fetch("new_fingerprint") != StrictModeGlobalLedger.missing_fingerprint
  end
  assert(name, !pending_preimage.nil?, "missing pending marker preimage ledger")
  if pending_preimage
    StrictModeGlobalLedger.append_change!(
      state_root,
      writer: "uninstall",
      target_path: pending_path,
      target_class: "installer-marker",
      old_fingerprint: pending_preimage.fetch("new_fingerprint"),
      new_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
      related_record_hash: complete_marker.fetch("marker_hash")
    )
  end

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected cross-writer pending delete refusal, got #{exitstatus}", output)
  assert(name, output.include?("pending marker delete ledger writer mismatch"), "missing cross-writer pending delete diagnostic", output)
  ledger_after = assert_global_ledger_valid(name, state_root)
  install_deletes = ledger_after.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, install_deletes.empty?, "cross-writer pending delete refusal appended install delete")
end

with_fixture do |_root, home, install_root|
  name = "install refuses duplicate pending delete ledger"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PENDING_MARKER_DELETE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_marker = read_json(complete_path)
  pending_path = install_root.join("install-transactions/#{complete_marker.fetch("transaction_id")}.pending.json")
  state_root = install_root.join("state")
  ledger_before = assert_global_ledger_valid(name, state_root)
  pending_preimage = ledger_before.reverse.find do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") != "delete" &&
      record.fetch("new_fingerprint") != StrictModeGlobalLedger.missing_fingerprint
  end
  assert(name, !pending_preimage.nil?, "missing pending marker preimage ledger")
  if pending_preimage
    2.times do
      StrictModeGlobalLedger.append_change!(
        state_root,
        writer: "install",
        target_path: pending_path,
        target_class: "installer-marker",
        old_fingerprint: pending_preimage.fetch("new_fingerprint"),
        new_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
        related_record_hash: complete_marker.fetch("marker_hash")
      )
    end
  end

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected duplicate pending delete refusal, got #{exitstatus}", output)
  assert(name, output.include?("duplicate pending marker delete ledger records"), "missing duplicate pending delete diagnostic", output)
end

with_fixture do |_root, home, install_root|
  name = "install preserves rollback writer when cleaning completed rollback pending marker"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_ROLLBACK_COMPLETE_MARKER" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted rollback failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  assert(name, read_json(pending_path).fetch("phase") == "rollback-in-progress", "interrupted rollback did not leave rollback-in-progress marker")
  assert_hash_valid(name, complete_path, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install after completed rollback cleanup failed", output)
  assert(name, !pending_path.exist?, "install did not clean completed rollback pending marker")
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  rollback_creates = ledger.select do |record|
    record.fetch("writer") == "rollback" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  install_creates = ledger.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  rollback_deletes = ledger.select do |record|
    record.fetch("writer") == "rollback" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, rollback_creates.size == 1, "completed rollback cleanup lost rollback complete-marker create")
  assert(name, install_creates.empty?, "completed rollback cleanup attributed complete-marker create to install")
  assert(name, rollback_deletes.size == 1, "completed rollback cleanup did not attribute pending delete to rollback")
end

with_fixture do |_root, home, install_root|
  name = "install refuses completed pending marker root drift"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_INSTALL_COMPLETE_MARKER" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  pending_marker = read_json(pending_path)
  complete_marker = read_json(complete_path)
  pending_marker["install_root"] = install_root.dirname.join("other-root").to_s
  complete_marker["install_root"] = pending_marker.fetch("install_root")
  write_hash_bound_json(pending_path, pending_marker, "marker_hash")
  write_hash_bound_json(complete_path, complete_marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected root-drift refusal, got #{exitstatus}", output)
  assert(name, output.include?("install_root mismatch"), "missing completed-pending root drift diagnostic", output)
  assert(name, pending_path.file?, "root-drift cleanup consumed pending marker")
end

with_fixture do |_root, home, install_root|
  name = "install refuses completed pending marker filename drift"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_INSTALL_COMPLETE_MARKER" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  pending_marker = read_json(pending_path)
  complete_marker = read_json(complete_path)
  pending_marker["transaction_id"] = "different-transaction"
  complete_marker["transaction_id"] = pending_marker.fetch("transaction_id")
  write_hash_bound_json(pending_path, pending_marker, "marker_hash")
  write_hash_bound_json(complete_path, complete_marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected filename-drift refusal, got #{exitstatus}", output)
  assert(name, output.include?("transaction_id mismatch filename"), "missing completed-pending filename drift diagnostic", output)
  assert(name, pending_path.file?, "filename-drift cleanup consumed pending marker")
end

with_fixture do |_root, home, install_root|
  name = "install refuses invalid completed pending phase before ledger repair"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  pending_marker = read_json(pending_path)
  assert(name, pending_marker.fetch("phase") == "post-activation-failed", "interrupted install did not publish post-activation-failed marker")
  complete_path = pending_path.dirname.join("#{pending_marker.fetch("transaction_id")}.complete.json")
  complete_marker = pending_marker.merge(
    "phase" => "complete",
    "updated_at" => pending_marker.fetch("updated_at"),
    "marker_hash" => ""
  )
  write_hash_bound_json(complete_path, complete_marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected invalid completed phase refusal, got #{exitstatus}", output)
  assert(name, output.include?("cannot be completed by pending cleanup"), "missing invalid completed phase diagnostic", output)
  assert(name, pending_path.file?, "invalid phase cleanup consumed pending marker")
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates = ledger.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates.empty?, "invalid completed phase repaired complete-marker ledger before refusing")
end

with_fixture do |_root, home, install_root|
  name = "install refuses cross-writer complete marker ledger"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_COMPLETE_MARKER_WRITE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_marker = read_json(complete_path)
  state_root = install_root.join("state")
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "uninstall",
    target_path: complete_path,
    target_class: "installer-marker",
    old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(complete_path),
    related_record_hash: complete_marker.fetch("marker_hash")
  )

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected cross-writer complete create refusal, got #{exitstatus}", output)
  assert(name, output.include?("complete marker ledger create writer mismatch"), "missing cross-writer complete create diagnostic", output)
  assert(name, pending_path.file?, "cross-writer complete create refusal consumed pending marker")
  ledger = assert_global_ledger_valid(name, state_root)
  install_creates = ledger.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, install_creates.empty?, "cross-writer complete create refusal appended install create")
end

with_fixture do |_root, home, install_root|
  name = "install refuses duplicate complete marker ledger"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_COMPLETE_MARKER_WRITE" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_marker = read_json(complete_path)
  state_root = install_root.join("state")
  2.times do
    StrictModeGlobalLedger.append_change!(
      state_root,
      writer: "install",
      target_path: complete_path,
      target_class: "installer-marker",
      old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
      new_fingerprint: StrictModeGlobalLedger.fingerprint(complete_path),
      related_record_hash: complete_marker.fetch("marker_hash")
    )
  end

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected duplicate complete create refusal, got #{exitstatus}", output)
  assert(name, output.include?("duplicate complete marker ledger creates"), "missing duplicate complete create diagnostic", output)
  assert(name, pending_path.file?, "duplicate complete create refusal consumed pending marker")
end

with_fixture do |_root, home, install_root|
  name = "install refuses unresolved pending marker before new transaction"
  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted install failure, got #{exitstatus}", output)
  pending_paths = Dir[install_root.join("install-transactions/*.pending.json")]
  assert(name, pending_paths.size == 1, "interrupted install did not leave one pending marker")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected pending-marker refusal, got #{exitstatus}", output)
  assert(name, output.include?("pending transaction markers require rollback/repair"), "missing unresolved pending diagnostic", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].size == 1, "pending refusal created another pending marker")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "pending refusal mutated Claude hooks")
end

with_fixture do |_root, home, install_root|
  name = "uninstall removes only exact strict selectors"
  run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "uninstall failed", output)

  manifest = assert_hash_valid(name, install_root.join("install-manifest.json"), "manifest_hash")
  baseline = assert_hash_valid(name, install_root.join("state/protected-install-baseline.json"), "baseline_hash")
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  %w[
    provider-config
    install-manifest
    protected-install-baseline
    installer-backup
    installer-marker
  ].each do |target_class|
    assert_ledger_has(name, ledger, "uninstall", target_class)
  end
  pending_markers = Dir[install_root.join("install-transactions/*.pending.json")]
  complete_markers = Dir[install_root.join("install-transactions/*.complete.json")]
  assert(name, pending_markers.empty?, "successful uninstall left pending transaction markers")
  assert(name, complete_markers.size == 2, "successful install+uninstall should publish two complete markers")
  assert(name, manifest.fetch("managed_hook_entries").empty?, "manifest still lists removed hook entries")
  assert(name, baseline.fetch("managed_hook_entries").empty?, "baseline still lists removed hook entries")
  assert(name, manifest.fetch("selected_output_contracts").empty?, "manifest still lists selected output contracts")
  assert(name, baseline.fetch("selected_output_contracts").empty?, "baseline still lists selected output contracts")
  assert_file_record_hashes(name, manifest.fetch("provider_config_records"))
  assert_file_record_hashes(name, baseline.fetch("provider_config_records"))

  claude = read_json(home.join(".claude/settings.json"))
  codex = read_json(home.join(".codex/hooks.json"))
  assert(name, strict_commands(claude).empty?, "Claude strict hooks were not removed")
  assert(name, strict_commands(codex).empty?, "Codex strict hooks were not removed")
  assert(name, claude.fetch("hooks").fetch("Stop").any? { |entry| entry.fetch("hooks").any? { |hook| hook["command"] == "echo keep-claude" } }, "Claude unrelated hook was removed")
  assert(name, codex.fetch("hooks").fetch("Stop").any? { |entry| entry.fetch("hooks").any? { |hook| hook["command"] == "echo keep-codex" } }, "Codex unrelated hook was removed")
end

with_fixture do |_root, home, install_root|
  name = "install cleans completed uninstall pending marker before reinstall"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_UNINSTALL_COMPLETE_MARKER" => "1" }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after uninstall complete marker publication"), "missing uninstall complete-marker interruption diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/uninstall-*.complete.json")].fetch(0))
  complete_before = complete_path.read
  assert(name, read_json(pending_path).fetch("phase") == "uninstalling", "interrupted uninstall did not leave uninstalling pending marker")
  assert_hash_valid(name, complete_path, "marker_hash")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "interrupted uninstall left Claude hooks active")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after completed uninstall cleanup failed", output)
  assert(name, !pending_path.exist?, "reinstall did not clean completed uninstall pending marker")
  assert(name, complete_path.read == complete_before, "reinstall rewrote old uninstall complete marker")
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates = ledger.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates.size == 1, "reinstall wrote duplicate uninstall complete-marker create")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "reinstall left pending markers")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "reinstall did not restore Claude hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "reinstall did not restore Codex hooks")
end

with_fixture do |_root, home, install_root|
  name = "install repairs uninstall complete marker ledger after write interruption"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_COMPLETE_MARKER_WRITE" => "1" }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after complete marker write before ledger append"), "missing uninstall complete-marker write diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/uninstall-*.complete.json")].fetch(0))
  complete_before = complete_path.read
  assert(name, read_json(pending_path).fetch("phase") == "uninstalling", "write-interrupted uninstall did not leave uninstalling pending marker")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_before = ledger_before.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_before.empty?, "write-interrupted uninstall already had complete-marker create")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after uninstall ledger repair failed", output)
  assert(name, !pending_path.exist?, "reinstall did not clean write-interrupted uninstall pending marker")
  assert(name, complete_path.read == complete_before, "reinstall rewrote write-interrupted uninstall complete marker")
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_after = ledger_after.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  pending_deletes_after = ledger_after.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, complete_creates_after.size == 1, "reinstall did not repair exactly one uninstall complete-marker create")
  assert(name, pending_deletes_after.size == 1, "reinstall did not attribute pending delete to uninstall")
end

with_fixture do |_root, home, install_root|
  name = "install repairs uninstall pending delete ledger after delete interruption"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PENDING_MARKER_DELETE" => "1" }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after pending marker delete before ledger append"), "missing uninstall pending-delete diagnostic", output)
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/uninstall-*.complete.json")].fetch(0))
  transaction_id = read_json(complete_path).fetch("transaction_id")
  pending_path = install_root.join("install-transactions/#{transaction_id}.pending.json")
  assert(name, !pending_path.exist?, "uninstall pending-delete interruption left pending marker")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_before = ledger_before.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_before.empty?, "uninstall pending-delete interruption already had pending delete ledger")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "reinstall after uninstall pending delete repair failed", output)
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_after = ledger_after.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_after.size == 1, "reinstall did not repair exactly one uninstall pending delete ledger")
end

with_fixture do |_root, home, install_root|
  name = "uninstall refuses occupied global lock before provider mutation"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  install_root.join("state-global.lock").mkpath
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("state-global.lock") && output.include?("another global transaction is active"), "missing global lock diagnostic", output)
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "uninstall removed Claude hooks while global lock was held")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "uninstall removed Codex hooks while global lock was held")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "locked uninstall created pending marker")
end

with_fixture do |_root, home, install_root|
  name = "uninstall refuses corrupted global ledger before provider mutation"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  corrupt_global_ledger!(install_root.join("state"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("global ledger chain invalid"), "missing global ledger diagnostic", output)
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "uninstall removed Claude hooks after ledger preflight failure")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "uninstall removed Codex hooks after ledger preflight failure")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "ledger preflight failure created pending marker")
end

with_fixture do |_root, home, install_root|
  name = "uninstall preserves same-command hook with nonmatching timeout selector"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  manifest_path = install_root.join("install-manifest.json")
  baseline_path = install_root.join("state/protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  selector = manifest.fetch("managed_hook_entries").find { |entry| entry.fetch("provider") == "claude" && entry.fetch("logical_event") == "stop" }.fetch("removal_selector")
  claude_path = home.join(".claude/settings.json")
  claude = read_json(claude_path)
  claude.fetch("hooks").fetch("Stop") << {
    "hooks" => [
      {
        "type" => "command",
        "command" => selector.fetch("command"),
        "timeout" => selector.fetch("provider_timeout_ms") + 1
      }
    ]
  }
  claude_path.write(JSON.pretty_generate(claude) + "\n")

  replacement = file_record(claude_path, "provider-config", "claude")
  replace_file_record!(manifest.fetch("provider_config_records"), replacement)
  replace_file_record!(baseline.fetch("provider_config_records"), replacement)
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  baseline["protected_file_inode_index"] = protected_file_inode_index([
    baseline.fetch("runtime_file_records"),
    baseline.fetch("runtime_config_records"),
    baseline.fetch("provider_config_records"),
    baseline.fetch("protected_config_records"),
    file_record(manifest_path, "install-manifest")
  ])
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, UNINSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "uninstall failed", output)
  remaining_claude = read_json(claude_path)
  remaining_strict = remaining_claude.fetch("hooks").values.flatten.flat_map { |entry| entry.fetch("hooks", []) }.
    select { |hook| hook["command"] == selector.fetch("command") }
  assert(name, remaining_strict.size == 1, "uninstall removed nonmatching timeout hook", remaining_claude.inspect)
  assert(name, remaining_strict.first.fetch("timeout") == selector.fetch("provider_timeout_ms") + 1, "remaining hook timeout mismatch", remaining_strict.inspect)
end

with_fixture do |_root, home, install_root|
  name = "uninstall refuses invalid managed hook output-contract plan before mutation"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  manifest_path = install_root.join("install-manifest.json")
  manifest = read_json(manifest_path)
  manifest["selected_output_contracts"] = [selected_output_contract("codex", "stop", "codex.stop.block")]
  write_hash_bound_json(manifest_path, manifest, "manifest_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, UNINSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("managed hook entry plan invalid"), "missing hook plan diagnostic", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "plan failure should not create pending markers")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "Claude hooks changed despite plan failure")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "Codex hooks changed despite plan failure")
end

with_fixture do |_root, home, install_root|
  name = "uninstall refuses active runtime tamper before provider mutation"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  active = install_root.join("active")
  FileUtils.rm_f(active)
  active.write("tampered\n")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)
  assert(name, output.include?("protected install baseline untrusted"), "missing protected baseline diagnostic", output)
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "uninstall removed Claude hooks after active tamper")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "uninstall removed Codex hooks after active tamper")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "active tamper uninstall created pending marker")
end

with_fixture do |_root, home, install_root|
  name = "malformed provider config is controlled failure"
  home.join(".claude/settings.json").write("{\"hooks\":{},\"hooks\":{}}\n")
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, output.include?("duplicate JSON object key"), "missing duplicate-key diagnostic", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "provider config preflight failure created pending marker")
  assert(name, !install_root.join("state/trusted-state-ledger-global.jsonl").exist?, "provider config preflight failure wrote global ledger")
  assert(name, Dir[install_root.join("releases/*")].empty?, "provider config preflight failure copied release")
end

with_fixture do |_root, home, install_root|
  name = "provider config symlink is refused before mutation"
  symlink_target = home.join("claude-target.json")
  symlink_target.write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
  FileUtils.rm_f(home.join(".claude/settings.json"))
  File.symlink(symlink_target, home.join(".claude/settings.json"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, output.include?("must not be a symlink"), "missing symlink refusal diagnostic", output)
  assert(name, read_json(symlink_target).fetch("hooks").empty?, "symlink target was mutated")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "provider config symlink preflight failure created pending marker")
  assert(name, !install_root.join("state/trusted-state-ledger-global.jsonl").exist?, "provider config symlink preflight failure wrote global ledger")
  assert(name, Dir[install_root.join("releases/*")].empty?, "provider config symlink preflight failure copied release")
end

with_fixture do |_root, home, install_root|
  name = "dangling provider config symlink is preflight refused cleanly"
  dangling_target = home.join("missing-claude-target.json")
  FileUtils.rm_f(home.join(".claude/settings.json"))
  File.symlink(dangling_target, home.join(".claude/settings.json"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, output.include?("must not be a symlink"), "missing dangling symlink refusal diagnostic", output)
  assert(name, !dangling_target.exist?, "dangling symlink target was created")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "dangling provider symlink preflight failure created pending marker")
  assert(name, !install_root.join("state/trusted-state-ledger-global.jsonl").exist?, "dangling provider symlink preflight failure wrote global ledger")
  assert(name, Dir[install_root.join("releases/*")].empty?, "dangling provider symlink preflight failure copied release")
end

with_fixture do |_root, home, install_root|
  name = "dangling Codex config symlink is preflight refused cleanly"
  dangling_target = home.join("missing-codex-config.toml")
  FileUtils.rm_f(home.join(".codex/config.toml"))
  File.symlink(dangling_target, home.join(".codex/config.toml"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, output.include?("Codex config must not be a symlink"), "missing dangling Codex symlink diagnostic", output)
  assert(name, !dangling_target.exist?, "dangling Codex config target was created")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "dangling Codex config preflight failure created pending marker")
  assert(name, !install_root.join("state/trusted-state-ledger-global.jsonl").exist?, "dangling Codex config preflight failure wrote global ledger")
  assert(name, Dir[install_root.join("releases/*")].empty?, "dangling Codex config preflight failure copied release")
end

with_fixture do |_root, home, install_root|
  name = "unsafe active path fails before provider config mutation"
  install_root.mkpath
  install_root.join("active").write("not a symlink\n")
  FileUtils.rm_f(home.join(".claude/settings.json"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, !home.join(".claude/settings.json").exist?, "provider config was touched after active-path preflight failure")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "active-path preflight failure created pending marker")
  assert(name, !install_root.join("state/trusted-state-ledger-global.jsonl").exist?, "active-path preflight failure wrote global ledger")
  assert(name, Dir[install_root.join("releases/*")].empty?, "active-path preflight failure copied release")
end

with_fixture do |_root, home, install_root|
  name = "install refuses invalid protected runtime config before provider mutation"
  config_root = install_root.join("config")
  config_root.mkpath
  config_root.join("runtime.env").write("STRICT_MODE_PHASE=discovery\n")
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)
  assert(name, output.include?("protected config validation failed"), "missing protected config validation diagnostic", output)
  assert(name, output.include?("runtime env key must be whitelisted"), "missing runtime whitelist diagnostic", output)
  claude = read_json(home.join(".claude/settings.json"))
  assert(name, strict_commands(claude).empty?, "provider config mutated despite invalid runtime.env", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "protected config preflight failure created pending marker")
  assert(name, !install_root.join("state/trusted-state-ledger-global.jsonl").exist?, "protected config preflight failure wrote global ledger")
  assert(name, Dir[install_root.join("releases/*")].empty?, "protected config preflight failure copied release")
end

with_fixture do |_root, home, install_root|
  name = "enforcing activation is fixture-gated"
  FileUtils.rm_f(home.join(".codex/hooks.json"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root, "--enforce")
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected enforcing install failure, got #{exitstatus}", output)
  assert(name, output.include?("enforcing activation fixture readiness failed"), "missing fixture-readiness diagnostic", output)
  assert(name, output.include?("missing codex stop decision-output fixture"), "missing concrete decision-output diagnostic", output)
  assert(name, !home.join(".codex/hooks.json").exist?, "enforcing failure wrote Codex hooks")
end

with_fixture do |_root, home, install_root|
  name = "discovery dry-run emits non-enforcing hook plan without provider mutation"
  before_claude = home.join(".claude/settings.json").read
  before_codex = home.join(".codex/hooks.json").read
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root, "--dry-run")
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "expected discovery dry-run success, got #{exitstatus}", output)
  plan = JSON.parse(output)
  assert(name, plan.fetch("plan_only") == true && plan.fetch("enforce") == false, "plan flags mismatch", output)
  assert(name, plan.fetch("providers") == %w[claude codex], "provider list mismatch", output)
  assert(name, plan.fetch("managed_hook_entries").size == 10, "unexpected discovery hook count", output)
  assert(name, plan.fetch("selected_output_contracts").empty?, "discovery dry-run selected output contracts", output)
  assert(name, plan.fetch("managed_hook_entries").all? { |entry| entry.fetch("enforcing") == false && entry.fetch("output_contract_id") == "" }, "discovery dry-run claimed enforcement", output)
  assert(name, home.join(".claude/settings.json").read == before_claude, "dry-run mutated Claude hooks")
  assert(name, home.join(".codex/hooks.json").read == before_codex, "dry-run mutated Codex hooks")
  assert(name, !install_root.exist?, "dry-run created install root")
end

with_fixture do |_root, home, install_root|
  name = "enforcing plan-only is fixture-gated and writes nothing"
  before_hooks = home.join(".codex/hooks.json").read
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only")
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected enforcing plan-only failure, got #{exitstatus}", output)
  assert(name, output.include?("enforcing activation fixture readiness failed"), "missing fixture-readiness diagnostic", output)
  assert(name, output.include?("missing codex stop decision-output fixture"), "missing concrete decision-output diagnostic", output)
  assert(name, home.join(".codex/hooks.json").read == before_hooks, "plan-only failure mutated Codex hooks")
  assert(name, !install_root.exist?, "plan-only failure created install root")
end

with_fixture do |root, home, install_root|
  name = "enforcing plan-only emits selected output hook plan without provider mutation"
  project_root = copied_project_with_codex_enforcing_fixtures(root)
  before_hooks = home.join(".codex/hooks.json").read
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only")
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "expected enforcing plan-only success, got #{exitstatus}", output)
  plan = JSON.parse(output)
  assert(name, plan.fetch("schema_version") == 1 && plan.fetch("plan_kind") == "install-plan", "plan header mismatch", output)
  assert(name, plan.fetch("plan_only") == true && plan.fetch("enforce") == true, "plan flags mismatch", output)
  assert(name, plan.fetch("providers") == ["codex"], "provider list mismatch", output)
  entries = plan.fetch("managed_hook_entries")
  selected = plan.fetch("selected_output_contracts")
  assert(name, entries.size == 5, "unexpected hook entry count", output)
  assert(name, selected.map { |record| [record.fetch("logical_event"), record.fetch("contract_id")] } == [["pre-tool-use", "codex.pre-tool-use.block"], ["stop", "codex.stop.block"]], "selected output contracts mismatch", output)
  pre = entries.find { |entry| entry.fetch("logical_event") == "pre-tool-use" }
  stop = entries.find { |entry| entry.fetch("logical_event") == "stop" }
  post = entries.find { |entry| entry.fetch("logical_event") == "post-tool-use" }
  assert(name, pre.fetch("enforcing") == true && pre.fetch("output_contract_id") == "codex.pre-tool-use.block", "pre-tool-use was not enforcing-bound", output)
  assert(name, stop.fetch("enforcing") == true && stop.fetch("output_contract_id") == "codex.stop.block", "stop was not enforcing-bound", output)
  assert(name, post.fetch("enforcing") == false && post.fetch("output_contract_id") == "", "post-tool-use should stay discovery-only", output)
  assert(name, entries.none? { |entry| entry.fetch("hook_event") == "PermissionRequest" }, "PermissionRequest included without optional proof", output)
  assert(name, plan.fetch("provider_config_paths").include?(home.join(".codex/hooks.json").to_s), "missing Codex hooks config path", output)
  assert(name, plan.fetch("provider_config_paths").include?(home.join(".codex/config.toml").to_s), "missing Codex TOML config path", output)
  assert(name, home.join(".codex/hooks.json").read == before_hooks, "plan-only mutated Codex hooks")
  assert(name, !install_root.exist?, "plan-only created install root")
end

with_fixture do |root, home, install_root|
  name = "enforcing plan-only honors exact provider-version fixtures"
  project_root = copied_project_with_codex_enforcing_fixtures(root, provider_version: "1.0.0")
  before_hooks = home.join(".codex/hooks.json").read

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only")
  assert_no_stacktrace("#{name} unknown", output)
  assert(name, exitstatus == 1, "expected default unknown-version failure, got #{exitstatus}", output)
  assert(name, output.include?("enforcing activation fixture readiness failed"), "missing fixture readiness diagnostic", output)
  assert(name, output.include?("missing codex stop decision-output fixture"), "missing exact-version readiness diagnostic", output)
  assert(name, home.join(".codex/hooks.json").read == before_hooks, "failed plan-only mutated Codex hooks")
  assert(name, !install_root.exist?, "failed plan-only created install root")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only", "--provider-version", "codex=1.0.0")
  assert_no_stacktrace("#{name} exact", output)
  assert(name, exitstatus.zero?, "expected exact-version plan-only success, got #{exitstatus}", output)
  plan = JSON.parse(output)
  selected = plan.fetch("selected_output_contracts")
  assert(name, plan.fetch("provider_versions") == { "codex" => "1.0.0" }, "provider version plan mismatch", output)
  assert(name, selected.size == 2 && selected.all? { |record| record.fetch("provider_version") == "1.0.0" }, "selected contracts did not use exact provider version", output)
  assert(name, plan.fetch("managed_hook_entries").select { |entry| entry.fetch("enforcing") }.map { |entry| entry.fetch("logical_event") } == %w[pre-tool-use stop], "exact-version plan did not enforce expected hooks", output)
  assert(name, home.join(".codex/hooks.json").read == before_hooks, "exact plan-only mutated Codex hooks")
  assert(name, !install_root.exist?, "exact plan-only created install root")
end

with_fixture do |root, home, install_root|
  name = "enforcing plan-only honors exact provider build-hash fixtures"
  build_hash = "c" * 64
  wrong_build_hash = "d" * 64
  project_root = copied_project_with_codex_enforcing_fixtures(root, provider_version: "1.0.0", provider_build_hash: build_hash)
  before_hooks = home.join(".codex/hooks.json").read

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only", "--provider-version", "codex=1.0.0")
  assert_no_stacktrace("#{name} missing build", output)
  assert(name, exitstatus == 1, "expected missing build-hash failure, got #{exitstatus}", output)
  assert(name, output.include?("enforcing activation fixture readiness failed"), "missing fixture readiness diagnostic", output)
  assert(name, output.include?("missing codex stop decision-output fixture"), "missing build-hash readiness diagnostic", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only", "--provider-version", "codex=1.0.0", "--provider-build-hash", "codex=#{wrong_build_hash}")
  assert_no_stacktrace("#{name} wrong build", output)
  assert(name, exitstatus == 1, "expected wrong build-hash failure, got #{exitstatus}", output)
  assert(name, output.include?("missing codex stop decision-output fixture"), "missing wrong-build readiness diagnostic", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce", "--plan-only", "--provider-version", "codex=1.0.0", "--provider-build-hash", "codex=#{build_hash}")
  assert_no_stacktrace("#{name} matching build", output)
  assert(name, exitstatus.zero?, "expected matching build-hash plan-only success, got #{exitstatus}", output)
  plan = JSON.parse(output)
  selected = plan.fetch("selected_output_contracts")
  assert(name, plan.fetch("provider_build_hashes") == { "codex" => build_hash }, "provider build hash plan mismatch", output)
  assert(name, selected.size == 2 && selected.all? { |record| record.fetch("provider_build_hash") == build_hash }, "selected contracts did not use exact provider build hash", output)
  assert(name, plan.fetch("managed_hook_entries").select { |entry| entry.fetch("enforcing") }.map { |entry| entry.fetch("logical_event") } == %w[pre-tool-use stop], "build-hash plan did not enforce expected hooks", output)
  assert(name, home.join(".codex/hooks.json").read == before_hooks, "build-hash plan-only mutated Codex hooks")
  assert(name, !install_root.exist?, "build-hash plan-only created install root")
end

with_fixture do |root, home, install_root|
  name = "enforcing install writes enforcing baseline and runtime blocks"
  project_root = copied_project_with_codex_enforcing_fixtures(root)
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, project_root.join("install.sh"), "--provider", "codex", "--install-root", install_root, "--enforce")
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "expected enforcing install success, got #{exitstatus}", output)

  manifest = assert_hash_valid(name, install_root.join("install-manifest.json"), "manifest_hash")
  baseline = assert_hash_valid(name, install_root.join("state/protected-install-baseline.json"), "baseline_hash")
  selected = manifest.fetch("selected_output_contracts")
  assert(name, selected.map { |record| [record.fetch("logical_event"), record.fetch("contract_id")] } == [["pre-tool-use", "codex.pre-tool-use.block"], ["stop", "codex.stop.block"]], "selected output contracts mismatch", selected.inspect)
  assert(name, baseline.fetch("selected_output_contracts") == selected, "baseline selected output contracts mismatch")
  entries = manifest.fetch("managed_hook_entries")
  assert(name, entries.select { |entry| entry.fetch("enforcing") }.map { |entry| entry.fetch("logical_event") } == %w[pre-tool-use stop], "wrong enforcing hook entries", entries.inspect)
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "Codex enforcing install did not write managed hooks")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "touch \"#{install_root.join('config/runtime.env')}\""
    }
  }
  project = root.join("project")
  project.mkpath
  hook_env = {
    "HOME" => home.to_s,
    "STRICT_INSTALL_ROOT" => install_root.to_s,
    "STRICT_STATE_ROOT" => install_root.join("state").to_s,
    "STRICT_PROJECT_DIR" => project.to_s
  }
  status, stdout, stderr = run_cmd_capture(
    hook_env,
    install_root.join("active/bin/strict-hook"),
    "--provider",
    "codex",
    "pre-tool-use",
    stdin_data: JSON.generate(payload) + "\n",
    chdir: project
  )
  assert_no_stacktrace("#{name} hook", stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit status", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "enforcing hook did not emit block output", stdout)
  assert(name, emitted.fetch("reason").include?("protected-root"), "enforcing hook reason missing preflight reason", stdout)
  assert(name, stderr.empty?, "enforcing provider contract should keep stderr empty", stderr)
  discovery_record = JSON.parse(install_root.join("state/discovery/codex-pre-tool-use.jsonl").read.lines.last)
  assert(name, discovery_record.fetch("mode") == "enforcing", "hook discovery record did not mark enforcing mode", discovery_record.inspect)
  assert(name, discovery_record.fetch("enforcement").fetch("emitted") == true, "hook discovery record missing enforcement emission", discovery_record.inspect)
end

with_fixture do |_root, home, install_root|
  name = "rollback restores provider configs after failed install"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  claude_after_failure = read_json(home.join(".claude/settings.json"))
  assert(name, !strict_commands(claude_after_failure).empty?, "fault did not happen after provider config mutation")
  pending_markers = Dir[install_root.join("install-transactions/*.pending.json")]
  assert(name, pending_markers.size == 1, "failed install did not leave one pending marker")
  assert(name, read_json(Pathname.new(pending_markers.fetch(0))).fetch("phase") == "post-activation-failed", "failed install did not publish post-activation-failed marker")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "rollback failed", output)
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  assert_ledger_has(name, ledger, "install", "provider-config")
  %w[
    provider-config
    install-release
    installer-marker
  ].each do |target_class|
    assert_ledger_has(name, ledger, "rollback", target_class)
  end
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "rollback left pending marker")
  assert(name, Dir[install_root.join("install-transactions/*.complete.json")].size == 1, "rollback did not publish complete marker")
  assert(name, !install_root.join("active").exist? && !install_root.join("active").symlink?, "rollback did not restore missing active runtime")
  assert(name, !install_root.join("install-manifest.json").exist?, "rollback did not restore missing install manifest")

  claude = read_json(home.join(".claude/settings.json"))
  codex = read_json(home.join(".codex/hooks.json"))
  assert(name, strict_commands(claude).empty?, "rollback left Claude strict hooks")
  assert(name, strict_commands(codex).empty?, "rollback left Codex strict hooks")
  assert(name, claude.fetch("hooks").fetch("Stop").any? { |entry| entry.fetch("hooks").any? { |hook| hook["command"] == "echo keep-claude" } }, "rollback lost Claude unrelated hook")
  assert(name, codex.fetch("hooks").fetch("Stop").any? { |entry| entry.fetch("hooks").any? { |hook| hook["command"] == "echo keep-codex" } }, "rollback lost Codex unrelated hook")
  assert(name, home.join(".codex/config.toml").read == "[features]\nexisting = true\n", "rollback did not restore Codex config.toml")
end

with_fixture do |_root, home, install_root|
  name = "rollback restores previous active runtime after failed reinstall"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "initial install failed", output)
  active = install_root.join("active")
  first_active_target = active.readlink.to_s

  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected reinstall failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  backup_manifest_path = install_root.join("install-backups/#{marker.fetch("transaction_id")}/backup-manifest.json")
  backup_manifest = read_json(backup_manifest_path)
  assert(name, marker.fetch("phase") == "post-activation-failed", "failed reinstall did not publish post-activation-failed marker")
  assert(name, marker.fetch("previous_active_runtime_path") == active.to_s, "marker did not bind previous active runtime path")
  assert(name, backup_manifest.fetch("previous_active_runtime_path") == marker.fetch("previous_active_runtime_path"), "backup active path does not match marker")
  assert(name, backup_manifest.fetch("previous_active_runtime_kind") == "symlink", "reinstall backup did not capture previous active symlink")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "rollback failed", output)
  assert(name, active.symlink? && active.readlink.to_s == first_active_target, "rollback did not restore previous active symlink")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "rollback did not restore previous Claude strict hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "rollback did not restore previous Codex strict hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback restores previous active runtime after active-link failure"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "initial install failed", output)
  active = install_root.join("active")
  first_active_target = active.readlink.to_s

  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_ACTIVE_LINK" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected active-link failure, got #{exitstatus}", output)
  assert(name, active.symlink? && active.readlink.to_s != first_active_target, "active-link fault did not advance active symlink")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "rollback failed", output)
  assert(name, active.symlink? && active.readlink.to_s == first_active_target, "rollback did not restore previous active symlink after active-link failure")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "rollback did not restore previous Claude strict hooks after active-link failure")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "rollback did not restore previous Codex strict hooks after active-link failure")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses unrelated active symlink before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_ACTIVE_LINK" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected active-link failure, got #{exitstatus}", output)

  active = install_root.join("active")
  unrelated_target = install_root.join("releases/unrelated")
  FileUtils.rm_f(active)
  File.symlink(unrelated_target.to_s, active)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("current active symlink does not match rollback transaction"), "missing unrelated active symlink diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "unrelated active symlink rollback advanced phase")
  assert(name, active.symlink? && active.readlink.to_s == unrelated_target.to_s, "rollback removed unrelated active symlink")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "unrelated active symlink rollback restored Claude hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses marker active path drift before phase advance"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "initial install failed", output)

  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected reinstall failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  marker["previous_active_runtime_path"] = ""
  write_hash_bound_json(pending_path, marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("previous active runtime path mismatch"), "missing marker active-path drift diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "active-path drift rollback advanced phase")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "active-path drift rollback restored Claude hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses stale pre-activation marker before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PENDING_MARKER" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  assert(name, read_json(pending_path).fetch("phase") == "pre-activation", "pending-marker fault should stop before activation phase advance")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("pre-activation marker requires installer repair"), "missing stale pre-activation rollback diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "pre-activation", "stale pre-activation rollback advanced pending marker phase")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "pending-marker fault mutated Claude hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).empty?, "pending-marker fault mutated Codex hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses occupied global lock before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  install_root.join("state-global.lock").mkpath
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("state-global.lock") && output.include?("another global transaction is active"), "missing global lock diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "locked rollback advanced pending marker phase")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "locked rollback restored Claude hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "locked rollback restored Codex hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses corrupted global ledger before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  corrupt_global_ledger!(install_root.join("state"))
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("global ledger chain invalid"), "missing global ledger diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "ledger preflight rollback advanced pending marker phase")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "ledger preflight rollback restored Claude hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "ledger preflight rollback restored Codex hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses tampered backup manifest"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  backup_manifest_path = Pathname.new(Dir[install_root.join("install-backups/*/backup-manifest.json")].fetch(0))
  backup_manifest = read_json(backup_manifest_path)
  backup_manifest["manifest_hash"] = "bad"
  backup_manifest_path.write(JSON.pretty_generate(backup_manifest) + "\n")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("manifest_hash mismatch"), "missing backup tamper diagnostic", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].size == 1, "tampered rollback consumed pending marker")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses transaction marker schema drift before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  marker["unexpected"] = true
  write_hash_bound_json(pending_path, marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("fields mismatch") && output.include?("extra unexpected"), "missing marker schema diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "marker schema rollback advanced phase")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses backup manifest schema drift before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  backup_manifest_path = Pathname.new(Dir[install_root.join("install-backups/*/backup-manifest.json")].fetch(0))
  backup_manifest = read_json(backup_manifest_path)
  backup_manifest.fetch("backup_file_records").first["unexpected"] = true
  write_hash_bound_json(backup_manifest_path, backup_manifest, "manifest_hash")
  marker["backup_manifest_hash"] = backup_manifest.fetch("manifest_hash")
  write_hash_bound_json(pending_path, marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("backup_file_records 0: fields mismatch"), "missing backup record schema diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "schema-drift rollback advanced phase")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses backup manifest summary drift before phase advance"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  backup_manifest_path = Pathname.new(Dir[install_root.join("install-backups/*/backup-manifest.json")].fetch(0))
  backup_manifest = read_json(backup_manifest_path)
  backup_manifest["provider_config_records"] = []
  write_hash_bound_json(backup_manifest_path, backup_manifest, "manifest_hash")
  marker["backup_manifest_hash"] = backup_manifest.fetch("manifest_hash")
  write_hash_bound_json(pending_path, marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("provider_config_records mismatch backup_file_records"), "missing backup summary drift diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "post-activation-failed", "summary-drift rollback advanced phase")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses tampered backup file content before restore"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  backup_manifest_path = Pathname.new(Dir[install_root.join("install-backups/*/backup-manifest.json")].fetch(0))
  backup_manifest = read_json(backup_manifest_path)
  claude_backup = backup_manifest.fetch("backup_file_records").find do |record|
    record.fetch("kind") == "provider-config" && record.fetch("provider") == "claude" && record.fetch("existed") == 1
  end
  backup_blob = backup_manifest_path.dirname.join(claude_backup.fetch("backup_relative_path"))
  backup_blob.write("{\"hooks\":{\"Stop\":[]}}\n")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("backup content_sha256 mismatch"), "missing backup content hash diagnostic", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].size == 1, "tampered backup rollback consumed pending marker")
  pending_marker = read_json(Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0)))
  assert(name, pending_marker.fetch("phase") == "post-activation-failed", "tampered backup validation should not advance rollback phase")
  claude = read_json(home.join(".claude/settings.json"))
  assert(name, !strict_commands(claude).empty?, "rollback restored from tampered backup content")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses post-restore drift before complete marker"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_TAMPER_AFTER_RESTORE" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("post-restore content_sha256 mismatch"), "missing post-restore drift diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  assert(name, read_json(pending_path).fetch("phase") == "rollback-in-progress", "post-restore drift did not leave rollback resumable")
  assert(name, Dir[install_root.join("install-transactions/*.complete.json")].empty?, "post-restore drift published complete marker")
end

with_fixture do |_root, home, install_root|
  name = "rollback resumes rollback-in-progress after post-restore drift"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_TAMPER_AFTER_RESTORE" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected first rollback failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  assert(name, read_json(pending_path).fetch("phase") == "rollback-in-progress", "first rollback did not leave rollback-in-progress marker")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "resumed rollback failed", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "resumed rollback left pending marker")
  assert(name, Dir[install_root.join("install-transactions/*.complete.json")].size == 1, "resumed rollback did not publish complete marker")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "resumed rollback left Claude strict hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback reuses complete marker after pending cleanup interruption"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_ROLLBACK_COMPLETE_MARKER" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after rollback complete marker publication"), "missing complete-marker interruption diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_before = complete_path.read
  assert(name, read_json(pending_path).fetch("phase") == "rollback-in-progress", "interrupted rollback did not leave rollback-in-progress marker")
  assert_hash_valid(name, complete_path, "marker_hash")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_before = ledger_before.select do |record|
    record.fetch("writer") == "rollback" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_before.size == 1, "interrupted rollback did not ledger exactly one complete-marker create")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "resumed rollback failed", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "resumed rollback left pending marker")
  assert(name, complete_path.read == complete_before, "resumed rollback rewrote complete marker")
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  complete_creates_after = ledger_after.select do |record|
    record.fetch("writer") == "rollback" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == complete_path.to_s &&
      record.fetch("operation") == "create"
  end
  assert(name, complete_creates_after.size == 1, "resumed rollback wrote duplicate complete-marker create")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "resumed rollback left Claude strict hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback repairs pending delete ledger after delete interruption"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PENDING_MARKER_DELETE" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("test fault after pending marker delete before ledger append"), "missing rollback pending-delete diagnostic", output)
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  transaction_id = read_json(complete_path).fetch("transaction_id")
  pending_path = install_root.join("install-transactions/#{transaction_id}.pending.json")
  assert(name, !pending_path.exist?, "rollback pending-delete interruption left pending marker")
  ledger_before = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_before = ledger_before.select do |record|
    record.fetch("writer") == "rollback" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_before.empty?, "rollback pending-delete interruption already had pending delete ledger")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected no-pending rollback after repair, got #{exitstatus}", output)
  assert(name, output.include?("no pending transaction markers"), "missing no-pending diagnostic after rollback repair", output)
  ledger_after = assert_global_ledger_valid(name, install_root.join("state"))
  deletes_after = ledger_after.select do |record|
    record.fetch("writer") == "rollback" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, deletes_after.size == 1, "rollback rerun did not repair exactly one pending delete ledger")
end

with_fixture do |_root, home, install_root|
  name = "rollback complete-only repair refuses stale install writer"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_COMPLETE_MARKER_WRITE" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted rollback failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_marker = read_json(complete_path)
  state_root = install_root.join("state")
  FileUtils.rm_f(pending_path)
  StrictModeGlobalLedger.append_change!(
    state_root,
    writer: "install",
    target_path: complete_path,
    target_class: "installer-marker",
    old_fingerprint: StrictModeGlobalLedger.missing_fingerprint,
    new_fingerprint: StrictModeGlobalLedger.fingerprint(complete_path),
    related_record_hash: complete_marker.fetch("marker_hash")
  )

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected stale-writer complete-only repair refusal, got #{exitstatus}", output)
  assert(name, output.include?("complete marker ledger create writer mismatch"), "missing stale-writer complete-only diagnostic", output)
  ledger = assert_global_ledger_valid(name, state_root)
  install_deletes = ledger.select do |record|
    record.fetch("writer") == "install" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s &&
      record.fetch("operation") == "delete"
  end
  assert(name, install_deletes.empty?, "stale-writer complete-only repair appended install pending delete")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses complete marker binding drift before pending cleanup"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_ROLLBACK_COMPLETE_MARKER" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected interrupted rollback failure, got #{exitstatus}", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  complete_path = Pathname.new(Dir[install_root.join("install-transactions/*.complete.json")].fetch(0))
  complete_marker = read_json(complete_path)
  complete_marker["backup_manifest_hash"] = "f" * 64
  write_hash_bound_json(complete_path, complete_marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback refusal, got #{exitstatus}", output)
  assert(name, output.include?("backup_manifest_hash mismatch pending marker"), "missing complete-marker binding diagnostic", output)
  assert(name, pending_path.file?, "complete-marker drift consumed pending marker")
  assert(name, read_json(pending_path).fetch("phase") == "rollback-in-progress", "complete-marker drift did not remain resumable")
  assert(name, complete_path.file?, "complete-marker drift removed complete marker")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses symlink provider config restore target"
  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_PROVIDER_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected install failure, got #{exitstatus}", output)

  symlink_target = home.join("rollback-target.json")
  symlink_target.write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
  FileUtils.rm_f(home.join(".claude/settings.json"))
  File.symlink(symlink_target, home.join(".claude/settings.json"))

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("rollback target must not be a symlink"), "missing symlink restore-target diagnostic", output)
  assert(name, read_json(symlink_target).fetch("hooks").empty?, "rollback followed provider config symlink target")
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].size == 1, "symlink rollback consumed pending marker")
end

with_fixture do |_root, home, install_root|
  name = "rollback restores hooks after failed uninstall"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_UNINSTALL_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].size == 1, "failed uninstall did not leave one pending marker")
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  backup_manifest = read_json(install_root.join("install-backups/#{marker.fetch("transaction_id")}/backup-manifest.json"))
  assert(name, marker.fetch("phase") == "uninstall-failed", "failed uninstall did not publish uninstall-failed marker")
  assert(name, marker.fetch("previous_active_runtime_path") == backup_manifest.fetch("previous_active_runtime_path"), "uninstall marker active path does not match backup manifest")
  ledger = assert_global_ledger_valid(name, install_root.join("state"))
  uninstall_marker_records = ledger.select do |record|
    record.fetch("writer") == "uninstall" &&
      record.fetch("target_class") == "installer-marker" &&
      record.fetch("target_path") == pending_path.to_s
  end
  assert(name, uninstall_marker_records.any? { |record| record.fetch("new_fingerprint").fetch("content_sha256") == Digest::SHA256.file(pending_path).hexdigest }, "uninstall-failed marker ledger record missing")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "fault did not happen after hook removal")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "rollback failed", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "rollback left pending uninstall marker")

  manifest = assert_hash_valid(name, install_root.join("install-manifest.json"), "manifest_hash")
  baseline = assert_hash_valid(name, install_root.join("state/protected-install-baseline.json"), "baseline_hash")
  assert(name, manifest.fetch("managed_hook_entries").size == 10, "rollback did not restore manifest hook entries")
  assert(name, baseline.fetch("managed_hook_entries").size == 10, "rollback did not restore baseline hook entries")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "rollback did not restore Claude strict hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "rollback did not restore Codex strict hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback resumes rollback-in-progress after uninstall recovery drift"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_UNINSTALL_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, UNINSTALL, "--provider", "all", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)

  exitstatus, output = run_cmd({ "HOME" => home.to_s, "STRICT_TEST_TAMPER_AFTER_RESTORE" => "1" }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected first rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("post-restore content_sha256 mismatch"), "missing uninstall recovery post-restore drift diagnostic", output)
  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  assert(name, read_json(pending_path).fetch("phase") == "rollback-in-progress", "first uninstall recovery did not leave rollback-in-progress marker")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "resumed uninstall recovery failed", output)
  assert(name, Dir[install_root.join("install-transactions/*.pending.json")].empty?, "resumed uninstall recovery left pending marker")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).size == 5, "resumed uninstall recovery did not restore Claude hooks")
  assert(name, strict_commands(read_json(home.join(".codex/hooks.json"))).size == 5, "resumed uninstall recovery did not restore Codex hooks")
end

with_fixture do |_root, home, install_root|
  name = "rollback refuses uninstall marker active path drift before phase advance"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  env = { "HOME" => home.to_s, "STRICT_TEST_FAIL_AFTER_UNINSTALL_CONFIGS" => "1" }
  exitstatus, output = run_cmd(env, UNINSTALL, "--provider", "claude", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected uninstall failure, got #{exitstatus}", output)

  pending_path = Pathname.new(Dir[install_root.join("install-transactions/*.pending.json")].fetch(0))
  marker = read_json(pending_path)
  marker["previous_active_runtime_path"] = ""
  write_hash_bound_json(pending_path, marker, "marker_hash")

  exitstatus, output = run_cmd({ "HOME" => home.to_s }, ROLLBACK, "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus == 1, "expected rollback failure, got #{exitstatus}", output)
  assert(name, output.include?("previous active runtime path mismatch"), "missing uninstall active-path drift diagnostic", output)
  assert(name, read_json(pending_path).fetch("phase") == "uninstall-failed", "uninstall active-path drift rollback advanced phase")
  assert(name, strict_commands(read_json(home.join(".claude/settings.json"))).empty?, "fault did not remove Claude hooks before rollback refusal")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook discovery log stores payload hash only"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  state_root = install_root.join("state")
  hook = install_root.join("active/bin/strict-hook")
  payload = "secret payload should not be persisted"
  stdout, stderr, status = Open3.capture3({ "HOME" => home.to_s, "STRICT_STATE_ROOT" => state_root.to_s }, hook.to_s, "--provider", "codex", "stop", stdin_data: payload)
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook failed", output)
  log = state_root.join("discovery/codex-stop.jsonl")
  assert(name, log.file?, "discovery log was not written")
  text = log.read
  record = JSON.parse(text.lines.last)
  assert(name, text.include?(Digest::SHA256.hexdigest(payload)), "payload hash missing from discovery log")
  assert(name, !text.include?(payload), "raw payload leaked into discovery log")
  assert(name, record.fetch("raw_payload_captured") == false, "raw payload capture should be disabled by default")
  assert(name, record.fetch("raw_payload_path") == "", "raw payload path should be empty by default")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook derives state root from custom active install path"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  hook = install_root.join("active/bin/strict-hook")
  payload = "{\"event\":\"stop\"}\n"
  stdout, stderr, status = Open3.capture3({ "HOME" => home.to_s }, hook.to_s, "--provider", "codex", "stop", stdin_data: payload)
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook failed", output)
  assert(name, install_root.join("state/discovery/codex-stop.jsonl").file?, "custom install-root discovery log was not written under install_root/state")
  assert(name, !home.join(".strict-mode/state/discovery/codex-stop.jsonl").exist?, "custom install-root hook wrote to default home state")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook provider env cannot enable raw payload capture"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  state_root = install_root.join("state")
  hook = install_root.join("active/bin/strict-hook")
  payload = "{\"event\":\"stop\",\"secret\":\"captured only when explicit\"}\n"
  env = {
    "HOME" => home.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s,
    "STRICT_CAPTURE_RAW_PAYLOADS" => "1"
  }
  stdout, stderr, status = Open3.capture3(env, hook.to_s, "--provider", "codex", "Stop", stdin_data: payload)
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook failed", output)

  log = state_root.join("discovery/codex-stop.jsonl")
  record = JSON.parse(log.read.lines.last)
  assert(name, record.fetch("provider_detection_decision") == "match", "raw capture should require matching provider proof")
  assert(name, record.fetch("raw_payload_captured") == false, "provider env enabled raw payload capture")
  assert(name, record.fetch("raw_payload_path") == "", "provider env should not expose a raw payload path")
  assert(name, log.read.include?(Digest::SHA256.hexdigest(payload)), "payload hash missing from discovery log")
  assert(name, !log.read.include?(payload), "raw payload leaked into JSONL log")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook protected runtime raw payload capture is explicit"
  write_runtime_env(install_root, "STRICT_CAPTURE_RAW_PAYLOADS=1\n")
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  state_root = install_root.join("state")
  hook = install_root.join("active/bin/strict-hook")
  payload = "{\"event\":\"stop\",\"secret\":\"captured only when explicit\"}\n"
  stdout, stderr, status = Open3.capture3({ "HOME" => home.to_s, "STRICT_STATE_ROOT" => state_root.to_s }, hook.to_s, "--provider", "codex", "Stop", stdin_data: payload)
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook failed", output)

  log = state_root.join("discovery/codex-stop.jsonl")
  record = JSON.parse(log.read.lines.last)
  raw_path = Pathname.new(record.fetch("raw_payload_path"))
  assert(name, record.fetch("provider_detection_decision") == "match", "raw capture should require matching provider proof")
  assert(name, record.fetch("raw_payload_captured") == true, "raw payload was not captured")
  assert(name, raw_path.to_s.start_with?(state_root.join("discovery/raw/codex/stop").to_s), "raw payload path escaped discovery raw dir")
  assert(name, raw_path.file?, "raw payload file missing")
  assert(name, raw_path.binread == payload, "raw payload content mismatch")
  assert(name, log.read.include?(Digest::SHA256.hexdigest(payload)), "payload hash missing from discovery log")
  assert(name, !log.read.include?(payload), "raw payload leaked into JSONL log")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook provider env cannot raise discovery payload cap"
  write_runtime_env(install_root, "STRICT_CAPTURE_RAW_PAYLOADS=1\n")
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  state_root = install_root.join("state")
  hook = install_root.join("active/bin/strict-hook")
  payload = "{\"event\":\"stop\",\"body\":\"#{'x' * 70_000}\"}\n"
  env = {
    "HOME" => home.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s,
    "STRICT_DISCOVERY_PAYLOAD_MAX_BYTES" => "200000"
  }
  stdout, stderr, status = Open3.capture3(env, hook.to_s, "--provider", "codex", "Stop", stdin_data: payload)
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook failed", output)

  log = state_root.join("discovery/codex-stop.jsonl")
  record = JSON.parse(log.read.lines.last)
  assert(name, record.fetch("payload_truncated") == true, "provider env raised discovery payload cap")
  assert(name, record.fetch("raw_payload_captured") == false, "truncated payload was captured")
  assert(name, record.fetch("raw_payload_path") == "", "truncated payload should not expose a raw payload path")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook provider mismatch blocks raw payload capture"
  write_runtime_env(install_root, "STRICT_CAPTURE_RAW_PAYLOADS=1\n")
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  state_root = install_root.join("state")
  hook = install_root.join("active/bin/strict-hook")
  payload = "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"tool_name\":\"Write\"}\n"
  env = {
    "HOME" => home.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s
  }
  stdout, stderr, status = Open3.capture3(env, hook.to_s, "--provider", "codex", "stop", stdin_data: payload)
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook should stay log-only on provider mismatch", output)
  assert(name, output.include?("strict-hook provider mismatch"), "missing provider mismatch diagnostic", output)

  log = state_root.join("discovery/codex-stop.jsonl")
  record = JSON.parse(log.read.lines.last)
  assert(name, record.fetch("provider") == "codex", "discovery record should preserve explicit provider")
  assert(name, record.fetch("detected_provider") == "claude", "detected provider mismatch was not logged")
  assert(name, record.fetch("provider_detection_decision") == "mismatch", "provider mismatch decision was not logged")
  assert(name, record.fetch("raw_payload_captured") == false, "provider mismatch captured raw payload")
  assert(name, record.fetch("raw_payload_path") == "", "provider mismatch should not expose a raw payload path")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook unsafe event names cannot escape discovery log directory"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  state_root = install_root.join("state")
  hook = install_root.join("active/bin/strict-hook")
  stdout, stderr, status = Open3.capture3({ "HOME" => home.to_s, "STRICT_STATE_ROOT" => state_root.to_s }, hook.to_s, "--provider", "codex", "../outside", stdin_data: "payload")
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook failed", output)
  assert(name, state_root.join("discovery/codex-unknown.jsonl").file?, "unsafe event did not normalize to unknown log")
  assert(name, !state_root.join("outside.jsonl").exist?, "unsafe event escaped discovery directory")
end

with_fixture do |_root, home, install_root|
  name = "strict-hook discovery log failure is controlled"
  exitstatus, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
  assert_no_stacktrace(name, output)
  assert(name, exitstatus.zero?, "install failed", output)

  bad_state_root = install_root.join("not-a-directory")
  bad_state_root.write("file blocks discovery dir\n")
  hook = install_root.join("active/bin/strict-hook")
  stdout, stderr, status = Open3.capture3({ "HOME" => home.to_s, "STRICT_STATE_ROOT" => bad_state_root.to_s }, hook.to_s, "--provider", "codex", "stop", stdin_data: "payload")
  output = stdout + stderr
  assert_no_stacktrace(name, output)
  assert(name, status.exitstatus.zero?, "strict-hook should stay log-only on discovery log failure", output)
  assert(name, output.include?("strict-hook discovery log failed"), "missing controlled discovery log failure diagnostic", output)
end

if $failures.empty?
  puts "installer tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
