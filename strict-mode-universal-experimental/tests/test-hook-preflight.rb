#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../tools/decision_contract_lib"
require_relative "../tools/fdr_cycle_lib"
require_relative "../tools/fdr_import_lib"
require_relative "../tools/fixture_readiness_lib"
require_relative "../tools/hook_entry_plan_lib"
require_relative "../tools/install_hook_plan_lib"
require_relative "../tools/metadata_lib"
require_relative "../tools/permission_decision_lib"
require_relative "../tools/preflight_record_lib"
require_relative "../tools/protected_baseline_lib"
require_relative "../tools/record_edit_lib"

ROOT = StrictModeMetadata.project_root
INSTALL = ROOT.join("install.sh")
INITIAL_JUDGE_HISTORY = [{ "cycle" => 0, "classification" => "initial", "summary" => "Initial challenge fired" }].freeze
POST_FIRST_JUDGE_HISTORY = [
  INITIAL_JUDGE_HISTORY.first,
  {
    "cycle" => 1,
    "classification" => "substantive",
    "summary" => "Где ты схалтурил?",
    "gaps" => "Где ты схалтурил?"
  }
].freeze

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

def run_cmd(env, *args, stdin_data: nil, chdir: nil)
  opts = {}
  opts[:stdin_data] = stdin_data if stdin_data
  opts[:chdir] = chdir.to_s if chdir
  stdout, stderr, status = Open3.capture3(env, *args.map(&:to_s), opts)
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

def runtime_file_records(release)
  Dir.glob(release.join("**/*").to_s).sort.each_with_object([]) do |file, records|
    path = Pathname.new(file)
    records << file_record(path, "runtime-file") if path.file?
  end.sort_by { |record| [record.fetch("path"), record.fetch("kind")] }
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

def decision_output_fixture_record(root, event, provider_action: "block")
  provider = "codex"
  contract_id = "codex.#{event}.#{provider_action}"
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
  stdout_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.stdout", JSON.generate({ "decision" => provider_action, "reason" => "blocked" }) + "\n")
  stderr_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.stderr", "")
  exit_code_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.exit-code", "0\n")
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => "unknown",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => "decision-output",
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => metadata.fetch("decision_contract_hash"),
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => [metadata_path, stdout_path, stderr_path, exit_code_path].map { |path| fixture_hash_entry(root, path) }.sort_by { |entry| entry.fetch("path") },
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => {
      "mode" => "unknown-only",
      "min_version" => "unknown",
      "max_version" => "unknown",
      "version_comparator" => "",
      "provider_build_hashes" => []
    },
    "fixture_record_hash" => ""
  }
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
end

def enable_codex_enforcement!(install_root, state_root, events: %w[pre-tool-use stop])
  active_root = Pathname.new(install_root.join("active").realpath)
  records = events.map do |event|
    decision_output_fixture_record(active_root, event, provider_action: event == "permission-request" ? "deny" : "block")
  end
  write_fixture_manifest(active_root, "codex", records)
  selected = StrictModeFixtureReadiness.selected_output_contracts(active_root, ["codex"])
  if events.include?("permission-request") && selected.none? { |record| record["logical_event"] == "permission-request" }
    manifest = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(active_root, "codex"))
    permission_record = manifest.fetch("records").find { |record| record["event"] == "permission-request" && record["contract_kind"] == "decision-output" }
    permission_metadata = StrictModeFixtureReadiness.decision_output_metadata(active_root, permission_record)
    selected << StrictModeFixtureReadiness.selected_output_contract_record(permission_record, permission_metadata, manifest.fetch("manifest_hash"))
    selected.sort_by! { |record| [record.fetch("provider"), record.fetch("logical_event"), record.fetch("contract_id")] }
  end

  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  config_path = manifest.fetch("managed_hook_entries").find { |entry| entry["provider"] == "codex" }.fetch("config_path")
  entries = StrictModeInstallHookPlan.managed_entries(
    "codex",
    config_path,
    install_root,
    state_root: state_root,
    selected_output_contracts: selected,
    enforce: true
  )
  fixture_records = StrictModeFixtureReadiness.fixture_manifest_records(active_root, ["codex"])
  runtime_records = runtime_file_records(active_root)
  [manifest, baseline].each do |record|
    record["managed_hook_entries"] = entries
    record["selected_output_contracts"] = selected
    record["fixture_manifest_records"] = fixture_records
    record["runtime_file_records"] = runtime_records
  end
  baseline["generated_hook_commands"] = entries.map { |entry| entry.slice("provider", "hook_event", "logical_event", "command") }

  write_hash_bound_json(manifest_path, manifest, "manifest_hash")
  manifest = read_json(manifest_path)
  baseline["install_manifest_hash"] = manifest.fetch("manifest_hash")
  index_records = %w[runtime_file_records runtime_config_records provider_config_records protected_config_records].flat_map { |field| baseline.fetch(field) }
  manifest_record = StrictModeProtectedBaseline.current_install_manifest_record(manifest_path, [])
  baseline["protected_file_inode_index"] = StrictModeProtectedBaseline.expected_inode_index(index_records + [manifest_record])
  write_hash_bound_json(baseline_path, baseline, "baseline_hash")
end

def assert_valid_preflight(name, preflight)
  errors = StrictModePreflightRecord.validate(preflight)
  assert(name, errors.empty?, "preflight contract invalid", errors.join("\n"))
end

def with_install(preinstall: nil)
  $cases += 1
  Dir.mktmpdir("strict-hook-preflight-") do |dir|
    root = Pathname.new(dir).realpath
    home = root.join("home")
    install_root = root.join("strict root")
    project = root.join("project")
    project.mkpath
    home.join(".claude").mkpath
    home.join(".codex").mkpath
    home.join(".claude/settings.json").write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
    home.join(".codex/hooks.json").write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
    home.join(".codex/config.toml").write("[features]\nexisting = true\n")
    preinstall.call(root, home, install_root, project) if preinstall
    status, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "codex", "--install-root", install_root)
    assert_no_stacktrace("install fixture", output)
    raise "install failed: #{output}" unless status.zero?

    yield root, home, install_root, install_root.join("state"), project
  end
end

def hook_env(home, install_root, state_root, project)
  {
    "HOME" => home.to_s,
    "STRICT_INSTALL_ROOT" => install_root.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s,
    "STRICT_PROJECT_DIR" => project.to_s
  }
end

def run_hook(home, install_root, state_root, project, payload)
  hook = install_root.join("active/bin/strict-hook")
  run_cmd(
    hook_env(home, install_root, state_root, project),
    hook,
    "--provider",
    "codex",
    "pre-tool-use",
    stdin_data: JSON.generate(payload) + "\n",
    chdir: project
  )
end

def run_hook_capture(home, install_root, state_root, project, payload)
  run_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
end

def run_hook_event_capture(home, install_root, state_root, project, event, payload)
  hook = install_root.join("active/bin/strict-hook")
  stdout, stderr, status = Open3.capture3(
    hook_env(home, install_root, state_root, project),
    hook.to_s,
    "--provider",
    "codex",
    event,
    stdin_data: JSON.generate(payload) + "\n",
    chdir: project.to_s
  )
  [status.exitstatus, stdout, stderr]
end

def codex_output_contract_id_for(event)
  {
    "pre-tool-use" => "codex.pre-tool-use.block",
    "stop" => "codex.stop.block",
    "permission-request" => "codex.permission-request.deny"
  }.fetch(event)
end

def run_enforcing_hook_event_capture(home, install_root, state_root, project, event, payload)
  hook = install_root.join("active/bin/strict-hook")
  env = hook_env(home, install_root, state_root, project).merge(
    "STRICT_ENFORCING_HOOK" => "1",
    "STRICT_OUTPUT_CONTRACT_ID" => codex_output_contract_id_for(event)
  )
  stdout, stderr, status = Open3.capture3(
    env,
    hook.to_s,
    "--provider",
    "codex",
    event,
    stdin_data: JSON.generate(payload) + "\n",
    chdir: project.to_s
  )
  [status.exitstatus, stdout, stderr]
end

def last_discovery_record(state_root, event = "pre-tool-use")
  log = state_root.join("discovery/codex-#{event}.jsonl")
  raise "#{log}: missing discovery log" unless log.file?

  JSON.parse(log.read.lines.last)
end

def fdr_session_identity(thread_id = "t1")
  StrictModeFdrCycle.session_identity("codex", { "thread_id" => thread_id })
end

def fdr_cycle_path(state_root, thread_id = "t1")
  identity = fdr_session_identity(thread_id)
  StrictModeFdrCycle.cycle_path(state_root, "codex", identity.fetch("session_key"))
end

def fdr_ledger_path(state_root, thread_id = "t1")
  identity = fdr_session_identity(thread_id)
  StrictModeFdrCycle.ledger_path(state_root, "codex", identity.fetch("session_key"))
end

def fdr_cycle_records(state_root, thread_id = "t1")
  StrictModeFdrCycle.load_cycle_records(fdr_cycle_path(state_root, thread_id))
end

def fdr_ledger_records(state_root, thread_id = "t1")
  StrictModeFdrCycle.load_session_ledger_records(fdr_ledger_path(state_root, thread_id))
end

def permission_decision_path(state_root, thread_id = "t1")
  identity = fdr_session_identity(thread_id)
  StrictModePermissionDecision.permission_decision_path(state_root, "codex", identity.fetch("session_key"))
end

def permission_decision_records(state_root, thread_id = "t1")
  StrictModePermissionDecision.load_records(permission_decision_path(state_root, thread_id))
end

def tool_intent_records(state_root, thread_id = "t1")
  identity = fdr_session_identity(thread_id)
  StrictModeRecordEdit.load_jsonl(StrictModeRecordEdit.tool_intent_log_path(state_root, "codex", identity.fetch("session_key")))
end

def tool_records(state_root, thread_id = "t1")
  identity = fdr_session_identity(thread_id)
  StrictModeRecordEdit.load_jsonl(StrictModeRecordEdit.tool_log_path(state_root, "codex", identity.fetch("session_key")))
end

def edit_records(state_root, thread_id = "t1")
  identity = fdr_session_identity(thread_id)
  StrictModeRecordEdit.load_jsonl(StrictModeRecordEdit.edit_log_path(state_root, "codex", identity.fetch("session_key")))
end

def assert_fdr_cycle_and_ledger(name, state_root, expected_decisions)
  cycles = fdr_cycle_records(state_root)
  ledgers = fdr_ledger_records(state_root)
  assert(name, StrictModeFdrCycle.validate_cycle_chain(fdr_cycle_path(state_root)).empty?, "FDR cycle chain invalid", cycles.inspect)
  assert(name, StrictModeFdrCycle.validate_session_ledger_chain(fdr_ledger_path(state_root)).empty?, "FDR session ledger chain invalid", ledgers.inspect)
  assert(name, cycles.map { |record| record.fetch("decision") } == expected_decisions, "FDR cycle decisions mismatch", cycles.inspect)
  assert(name, ledgers.length == cycles.length, "FDR cycle ledger coverage mismatch", ledgers.inspect)
  cycles.zip(ledgers).each do |cycle, ledger|
    assert(name, ledger.fetch("related_record_hash") == cycle.fetch("record_hash"), "ledger related hash does not bind cycle", ledger.inspect)
    assert(name, ledger.fetch("target_class") == "fdr-cycle-log" && ledger.fetch("operation") == "append", "ledger target/operation mismatch", ledger.inspect)
  end
  cycles
end

with_install do |_root, home, install_root, state_root, project|
  name = "PermissionRequest network deny writes permission decision evidence"
  enable_codex_enforcement!(install_root, state_root, events: %w[pre-tool-use stop permission-request])
  payload = {
    "event" => "permission-request",
    "thread_id" => "t1",
    "request_id" => "r-net",
    "operation" => "network",
    "access_mode" => "network-connect",
    "url" => "https://example.com/api",
    "can_approve" => true
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "permission-request", payload)
  assert(name, status.zero?, "permission deny should use provider deny contract", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "deny", "wrong provider decision", stdout)
  records = permission_decision_records(state_root)
  assert(name, records.length == 1, "permission decision record missing", records.inspect)
  record = records.first
  assert(name, record.fetch("decision") == "deny", "wrong record decision", record.inspect)
  assert(name, record.fetch("reason_code") == "deny-network", "wrong permission reason", record.inspect)
  assert(name, record.fetch("network_tuple_list").first == { "scheme" => "https", "host" => "example.com", "port" => 443, "operation" => "connect" }, "wrong network tuple", record.inspect)
  assert(name, StrictModePermissionDecision.validate_chain(permission_decision_path(state_root)).empty?, "permission decision chain invalid", records.inspect)
  ledgers = fdr_ledger_records(state_root)
  assert(name, ledgers.length == 1, "permission decision ledger missing", ledgers.inspect)
  assert(name, ledgers.first.fetch("target_class") == "permission-decision-log" && ledgers.first.fetch("operation") == "append", "ledger target mismatch", ledgers.inspect)
  assert(name, ledgers.first.fetch("related_record_hash") == record.fetch("record_hash"), "ledger does not bind permission decision", ledgers.inspect)
  discovery = last_discovery_record(state_root, "permission-request")
  assert(name, discovery.fetch("permission_decision").fetch("recorded") == true, "discovery did not report permission evidence", discovery.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "PermissionRequest filesystem write under protected root is denied with evidence"
  enable_codex_enforcement!(install_root, state_root, events: %w[pre-tool-use stop permission-request])
  payload = {
    "event" => "permission-request",
    "thread_id" => "t1",
    "request_id" => "r-fs",
    "operation" => "filesystem",
    "access_mode" => "write",
    "filesystem" => {
      "paths" => [install_root.join("config/runtime.env").to_s],
      "recursive" => false,
      "scope" => "file"
    },
    "can_approve" => true
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "permission-request", payload)
  assert(name, status.zero?, "permission protected-root deny should use provider deny contract", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "deny", "wrong provider decision", stdout)
  record = permission_decision_records(state_root).first
  assert(name, record.fetch("reason_code") == "deny-protected-root", "wrong permission reason", record.inspect)
  assert(name, record.fetch("normalized_path_list").include?(install_root.join("config/runtime.env").to_s), "missing normalized protected path", record.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "PermissionRequest patch raw content is scanned for stubs"
  enable_codex_enforcement!(install_root, state_root, events: %w[pre-tool-use stop permission-request])
  payload = {
    "event" => "permission-request",
    "thread_id" => "t1",
    "request_id" => "r-patch",
    "operation" => "write",
    "tool_name" => "apply_patch",
    "tool_input" => {
      "patch" => "*** Begin Patch\n*** Add File: src/todo.js\n@@\n+// TODO implement later\n*** End Patch\n"
    },
    "can_approve" => true
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "permission-request", payload)
  assert(name, status.zero?, "permission stub deny should use provider deny contract", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "deny", "wrong provider decision", stdout)
  record = permission_decision_records(state_root).first
  assert(name, record.fetch("reason_code") == "deny-policy", "raw patch stub was not mapped to deny-policy", record.inspect)
  assert(name, record.fetch("requested_tool_kind") == "patch", "wrong requested tool kind", record.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "PermissionRequest read-only project path records allow before provider allow"
  enable_codex_enforcement!(install_root, state_root, events: %w[pre-tool-use stop permission-request])
  project.join("README.md").write("# test\n")
  payload = {
    "event" => "permission-request",
    "thread_id" => "t1",
    "request_id" => "r-read",
    "operation" => "filesystem",
    "access_mode" => "read",
    "filesystem" => {
      "paths" => ["README.md"],
      "recursive" => false,
      "scope" => "file"
    },
    "can_approve" => true
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "permission-request", payload)
  assert(name, status.zero?, "permission allow should not fail", stdout + stderr)
  assert(name, stdout.empty? && stderr.empty?, "permission allow should not emit deny output", stdout + stderr)
  record = permission_decision_records(state_root).first
  assert(name, record.fetch("decision") == "allow", "wrong record decision", record.inspect)
  assert(name, record.fetch("reason_code") == "allow-read-only", "wrong allow reason", record.inspect)
  assert(name, record.fetch("normalized_path_list") == [project.join("README.md").to_s], "wrong allow path", record.inspect)
  discovery = last_discovery_record(state_root, "permission-request")
  assert(name, discovery.fetch("enforcement").fetch("emitted") == false, "allow emitted provider output", discovery.inspect)
  assert(name, discovery.fetch("permission_decision").fetch("recorded") == true, "allow evidence not reported", discovery.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "PermissionRequest record failure still emits deny-record-failure"
  enable_codex_enforcement!(install_root, state_root, events: %w[pre-tool-use stop permission-request])
  bad_path = permission_decision_path(state_root)
  bad_path.mkpath
  payload = {
    "event" => "permission-request",
    "thread_id" => "t1",
    "request_id" => "r-net",
    "operation" => "network",
    "access_mode" => "network-connect",
    "url" => "https://example.com/api",
    "can_approve" => true
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "permission-request", payload)
  assert(name, status.zero?, "record failure should still use provider deny contract", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "deny", "wrong provider decision", stdout)
  assert(name, emitted.fetch("reason").include?("deny-record-failure"), "provider deny did not mention record failure", stdout)
  discovery = last_discovery_record(state_root, "permission-request")
  summary = discovery.fetch("permission_decision")
  assert(name, summary.fetch("recorded") == false && summary.fetch("reason_code") == "deny-record-failure", "wrong discovery failure summary", discovery.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre and post tool write records intent tool and edit evidence"
  enable_codex_enforcement!(install_root, state_root)
  pre_payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "write",
    "tool_input" => {
      "file_path" => "src/new.js",
      "content" => "console.log('ok');\n"
    }
  }
  post_payload = pre_payload.merge("event" => "post-tool-use")

  pre_status, pre_stdout, pre_stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", pre_payload)
  assert(name, pre_status.zero?, "pre-tool write should allow", pre_stdout + pre_stderr)
  assert(name, pre_stdout.empty? && pre_stderr.empty?, "allowed pre-tool emitted output", pre_stdout + pre_stderr)
  intent = tool_intent_records(state_root).first
  assert(name, intent.fetch("tool_kind") == "write", "wrong intent kind", intent.inspect)
  assert(name, intent.fetch("write_intent") == "write", "wrong intent write intent", intent.inspect)
  assert(name, intent.fetch("normalized_path_list") == [project.join("src/new.js").to_s], "wrong intent path list", intent.inspect)
  assert(name, StrictModeRecordEdit.validate_tool_intent_record(intent).empty?, "intent record invalid", intent.inspect)
  bad_intent = JSON.parse(JSON.generate(intent.merge("normalized_path_list" => ["src/new.js"])))
  bad_errors = StrictModeRecordEdit.validate_tool_intent_record(bad_intent)
  assert(name, bad_errors.include?("normalized_path_list entries must be absolute paths or unknown"), "relative intent path was accepted", bad_errors.inspect)
  pre_record = last_discovery_record(state_root, "pre-tool-use")
  assert(name, pre_record.fetch("tool_intent").fetch("recorded") == true, "pre-tool discovery missing intent summary", pre_record.inspect)

  post_status, post_stdout, post_stderr = run_hook_event_capture(home, install_root, state_root, project, "post-tool-use", post_payload)
  assert(name, post_status.zero?, "post-tool should allow after recording", post_stdout + post_stderr)
  assert(name, post_stdout.empty?, "post-tool should not emit stdout", post_stdout)
  tool_record = tool_records(state_root).first
  edit_record = edit_records(state_root).first
  assert(name, tool_record.fetch("pre_tool_intent_seq") == intent.fetch("seq"), "tool did not link intent seq", tool_record.inspect)
  assert(name, tool_record.fetch("pre_tool_intent_hash") == intent.fetch("intent_hash"), "tool did not link intent hash", tool_record.inspect)
  assert(name, edit_record.fetch("action") == "create", "wrong edit action", edit_record.inspect)
  assert(name, edit_record.fetch("path") == project.join("src/new.js").to_s, "wrong edit path", edit_record.inspect)
  assert(name, StrictModeRecordEdit.validate_tool_record(tool_record).empty?, "tool record invalid", tool_record.inspect)
  assert(name, StrictModeRecordEdit.validate_edit_record(edit_record).empty?, "edit record invalid", edit_record.inspect)
  ledgers = fdr_ledger_records(state_root)
  assert(name, ledgers.map { |ledger| ledger.fetch("target_class") }.include?("tool-intent-log"), "missing tool-intent ledger", ledgers.inspect)
  assert(name, ledgers.map { |ledger| ledger.fetch("target_class") }.include?("tool-log"), "missing tool ledger", ledgers.inspect)
  assert(name, ledgers.map { |ledger| ledger.fetch("target_class") }.include?("edit-log"), "missing edit ledger", ledgers.inspect)
  post_record = last_discovery_record(state_root, "post-tool-use")
  assert(name, post_record.fetch("post_tool_record").fetch("edit_count") == 1, "post-tool discovery missing edit count", post_record.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "post tool without matching pre intent records unresolved zero link"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "post-tool-use",
    "thread_id" => "t1",
    "tool_name" => "edit",
    "tool_input" => {
      "file_path" => "src/existing.js",
      "old_string" => "old",
      "new_string" => "new"
    }
  }

  status, stdout, stderr = run_hook_event_capture(home, install_root, state_root, project, "post-tool-use", payload)
  assert(name, status.zero?, "post-tool without intent should still allow", stdout + stderr)
  tool_record = tool_records(state_root).first
  edit_record = edit_records(state_root).first
  assert(name, tool_record.fetch("pre_tool_intent_seq") == 0, "unmatched tool did not use zero intent seq", tool_record.inspect)
  assert(name, tool_record.fetch("pre_tool_intent_hash") == "0" * 64, "unmatched tool did not use zero intent hash", tool_record.inspect)
  assert(name, edit_record.fetch("action") == "modify", "wrong edit action", edit_record.inspect)
  post_record = last_discovery_record(state_root, "post-tool-use")
  assert(name, post_record.fetch("post_tool_record").fetch("pre_tool_intent_seq") == 0, "discovery did not expose unresolved intent", post_record.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool intent dangling symlink fails closed before append"
  enable_codex_enforcement!(install_root, state_root)
  identity = fdr_session_identity("t-symlink")
  intent_path = StrictModeRecordEdit.tool_intent_log_path(state_root, "codex", identity.fetch("session_key"))
  symlink_target = project.join("unexpected-intent-target.jsonl")
  File.symlink(symlink_target.to_s, intent_path.to_s)
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t-symlink",
    "tool_name" => "write",
    "tool_input" => {
      "file_path" => "src/new.js",
      "content" => "console.log('ok');\n"
    }
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control record-failure exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "record-failure did not block", stdout)
  assert(name, !symlink_target.exist?, "dangling symlink target was created", symlink_target.to_s)
  discovery = last_discovery_record(state_root, "pre-tool-use")
  assert(name, discovery.fetch("preflight").fetch("reason_code") == "preflight-error", "record failure did not fail closed", discovery.inspect)
  assert(name, discovery.fetch("tool_intent").fetch("recorded") == false, "record failure reported successful intent", discovery.inspect)
  assert(name, discovery.fetch("tool_intent").fetch("reason") == "record-failure", "wrong intent failure reason", discovery.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool emits provider block output from selected contract"
  enable_codex_enforcement!(install_root, state_root)
  command = "touch \"#{install_root.join('config/runtime.env')}\""
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => command
    }
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "provider output did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected-root"), "provider output reason missing preflight reason", stdout)
  assert(name, stderr.empty?, "provider block contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root)
  assert(name, record.fetch("mode") == "enforcing", "discovery record did not mark enforcing mode", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("emitted") == true, "enforcement emission not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.pre-tool-use.block", "wrong output contract", enforcement.inspect)
  assert(name, record.fetch("trusted_state_written") == false, "enforcement hook wrote trusted state")
end

destructive_pattern_preinstall = lambda do |_root, _home, install_root, _project|
  config_root = install_root.join("config")
  config_root.mkpath
  config_root.join("destructive-patterns.txt").write("shell-ere git[[:space:]]+reset[[:space:]]+--hard\n")
  File.chmod(0o600, config_root.join("destructive-patterns.txt"))
end

with_install(preinstall: destructive_pattern_preinstall) do |_root, home, install_root, state_root, project|
  name = "enforcing destructive pre-tool confirmation is exact and one-shot"
  enable_codex_enforcement!(install_root, state_root)
  command = "git reset --hard HEAD"
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => command
    }
  }

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  approval_hash = emitted.fetch("reason")[/strict-mode confirm ([0-9a-f]{64})/, 1]
  assert(name, emitted.fetch("decision") == "block", "initial destructive command did not block", stdout)
  assert(name, approval_hash && approval_hash.length == 64, "block output missing exact confirmation hash", stdout)
  pending_files = Dir.glob(state_root.join("pending-destructive-codex-*-#{approval_hash}.json").to_s)
  assert(name, pending_files.length == 1, "pending approval file missing", pending_files.inspect)
  pending = JSON.parse(Pathname.new(pending_files.first).read)
  assert(name, pending.fetch("next_user_prompt_marker") == "prompt-seq:1", "pending marker mismatch", pending.inspect)
  assert(name, pending.fetch("command_hash_source") == "shell-string", "pending command hash source mismatch", pending.inspect)
  first_record = last_discovery_record(state_root)
  assert(name, first_record.fetch("trusted_state_written") == true, "pending approval write not recorded", first_record.inspect)
  audit_path = state_root.join("destructive-log.jsonl")
  audit_path.delete if audit_path.file?
  replay_status, replay_stdout, replay_stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, replay_stdout + replay_stderr)
  assert(name, replay_status.zero?, "pending replay should still emit provider block", replay_stdout + replay_stderr)
  replay_hash = JSON.parse(replay_stdout).fetch("reason")[/strict-mode confirm ([0-9a-f]{64})/, 1]
  assert(name, replay_hash == approval_hash, "pending replay changed approval hash", replay_stdout)
  replay_actions = audit_path.read.lines.map { |line| JSON.parse(line).fetch("action") }
  assert(name, replay_actions == %w[blocked], "pending replay did not restore blocked audit", replay_actions.inspect)

  prompt_payload = {
    "event" => "user-prompt-submit",
    "thread_id" => "t1",
    "prompt" => "please proceed\nstrict-mode confirm #{approval_hash}\n"
  }
  prompt_status, prompt_stdout, prompt_stderr = run_hook_event_capture(home, install_root, state_root, project, "user-prompt-submit", prompt_payload)
  assert_no_stacktrace(name, prompt_stdout + prompt_stderr)
  assert(name, prompt_status.zero?, "user prompt hook failed", prompt_stdout + prompt_stderr)
  marker_files = Dir.glob(state_root.join("confirm-codex-*-#{approval_hash}").to_s)
  assert(name, marker_files.length == 1, "confirmation marker was not created", marker_files.inspect)
  marker = JSON.parse(Pathname.new(marker_files.first).read)
  assert(name, marker.fetch("approval_prompt_seq") == 1, "marker prompt seq mismatch", marker.inspect)
  assert(name, marker.fetch("pending_record_hash") == pending.fetch("pending_record_hash"), "marker pending hash mismatch", marker.inspect)

  retry_status, retry_stdout, retry_stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, retry_stdout + retry_stderr)
  assert(name, retry_status.zero?, "confirmed destructive command should exit cleanly", retry_stdout + retry_stderr)
  assert(name, retry_stdout.empty? && retry_stderr.empty?, "confirmed destructive command should not emit block output", retry_stdout + retry_stderr)
  consumed_files = Dir.glob(state_root.join("consumed-confirm-codex-*-#{approval_hash}.json").to_s)
  assert(name, consumed_files.length == 1, "confirmation tombstone missing", consumed_files.inspect)
  assert(name, marker_files.none? { |path| Pathname.new(path).exist? }, "active marker still exists after consumption")

  retry_record = last_discovery_record(state_root)
  assert(name, retry_record.fetch("preflight").fetch("reason_code") == "destructive-confirmed", "confirmed allow reason mismatch", retry_record.inspect)
  actions = Pathname.new(state_root.join("destructive-log.jsonl")).read.lines.map { |line| JSON.parse(line).fetch("action") }
  assert(name, actions == %w[blocked confirmed consumed], "destructive audit action chain mismatch", actions.inspect)
  ledgers = fdr_ledger_records(state_root)
  assert(name, StrictModeFdrCycle.validate_session_ledger_chain(fdr_ledger_path(state_root)).empty?, "session ledger invalid", ledgers.inspect)
  assert(name, ledgers.map { |entry| entry.fetch("target_class") }.include?("consumed-tombstone"), "missing consumed tombstone ledger", ledgers.inspect)
  global_errors = StrictModeGlobalLedger.validate_chain(StrictModeGlobalLedger.ledger_path(state_root))
  assert(name, global_errors.empty?, "global ledger invalid", global_errors.join("\n"))

  second_retry_status, second_retry_stdout, second_retry_stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, second_retry_stdout + second_retry_stderr)
  assert(name, second_retry_status.zero?, "second retry should emit provider block contract", second_retry_stdout + second_retry_stderr)
  second_emitted = JSON.parse(second_retry_stdout)
  assert(name, second_emitted.fetch("decision") == "block", "consumed confirmation authorized a second execution", second_retry_stdout)
end

with_install(preinstall: destructive_pattern_preinstall) do |_root, home, install_root, state_root, project|
  name = "destructive confirmation ignores generic affirmation"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "git reset --hard HEAD"
    }
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "initial destructive block failed", stdout + stderr)
  approval_hash = JSON.parse(stdout).fetch("reason")[/strict-mode confirm ([0-9a-f]{64})/, 1]
  assert(name, approval_hash, "missing confirmation hash", stdout)

  prompt_payload = {
    "event" => "user-prompt-submit",
    "thread_id" => "t1",
    "prompt" => "yes\n"
  }
  prompt_status, prompt_stdout, prompt_stderr = run_hook_event_capture(home, install_root, state_root, project, "user-prompt-submit", prompt_payload)
  assert_no_stacktrace(name, prompt_stdout + prompt_stderr)
  assert(name, prompt_status.zero?, "user prompt hook failed", prompt_stdout + prompt_stderr)
  marker_files = Dir.glob(state_root.join("confirm-codex-*-#{approval_hash}").to_s)
  assert(name, marker_files.empty?, "generic affirmation created confirmation marker", marker_files.inspect)
end

with_install(preinstall: destructive_pattern_preinstall) do |_root, home, install_root, state_root, project|
  name = "destructive confirmation requires marker ledger coverage"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "git reset --hard HEAD"
    }
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "initial destructive block failed", stdout + stderr)
  approval_hash = JSON.parse(stdout).fetch("reason")[/strict-mode confirm ([0-9a-f]{64})/, 1]
  prompt_payload = {
    "event" => "user-prompt-submit",
    "thread_id" => "t1",
    "prompt" => "strict-mode confirm #{approval_hash}\n"
  }
  prompt_status, prompt_stdout, prompt_stderr = run_hook_event_capture(home, install_root, state_root, project, "user-prompt-submit", prompt_payload)
  assert_no_stacktrace(name, prompt_stdout + prompt_stderr)
  assert(name, prompt_status.zero?, "user prompt hook failed", prompt_stdout + prompt_stderr)
  ledger_path = fdr_ledger_path(state_root)
  kept = ledger_path.read.lines.reject { |line| JSON.parse(line).fetch("target_class") == "approval-marker" }
  ledger_path.write(kept.join)

  retry_status, retry_stdout, retry_stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, retry_stdout + retry_stderr)
  assert(name, retry_status.zero?, "ledgerless marker retry should emit provider block contract", retry_stdout + retry_stderr)
  emitted = JSON.parse(retry_stdout)
  assert(name, emitted.fetch("decision") == "block", "ledgerless marker authorized destructive allow", retry_stdout)
  retry_record = last_discovery_record(state_root)
  assert(name, retry_record.fetch("preflight").fetch("reason_code") == "preflight-error", "ledgerless marker did not fail closed", retry_record.inspect)
  assert(name, Dir.glob(state_root.join("consumed-confirm-codex-*-#{approval_hash}.json").to_s).empty?, "ledgerless marker was consumed")
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop emits provider continuation block output"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "stop",
    "thread_id" => "t1"
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider stop contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "provider stop output did not block", stdout)
  assert(name, emitted.fetch("reason").include?("stop guard"), "provider stop output reason missing guard reason", stdout)
  assert(name, stderr.empty?, "provider stop contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root, "stop")
  assert(name, record.fetch("mode") == "enforcing", "discovery record did not mark enforcing mode", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("emitted") == true, "stop enforcement emission not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.stop.block", "wrong stop output contract", enforcement.inspect)
  assert(name, enforcement.fetch("judge").fetch("attempted") == false, "empty stop response should not invoke judge", enforcement.inspect)
  cycles = assert_fdr_cycle_and_ledger(name, state_root, ["skipped-no-turn-text"])
  assert(name, cycles.first.fetch("challenge_reason") == "no-normalized-turn-text", "empty response cycle reason mismatch", cycles.inspect)
end

with_install do |_root, _home, _install_root, state_root, project|
  name = "FDR cycle append refusal preserves occupied session lock"
  payload = { "event" => "stop", "thread_id" => "t1" }
  context = StrictModeFdrCycle.context(provider: "codex", payload: payload, cwd: project, project_dir: project)
  lock_path = StrictModeFdrCycle.lock_path(state_root, "codex", context.fetch("session_key"))
  lock_path.mkpath
  lock_path.join("owner.json").write("occupied\n")
  begin
    StrictModeFdrCycle.append_cycle!(
      state_root,
      context,
      decision: "skipped-no-turn-text",
      challenge_reason: "no-normalized-turn-text"
    )
    assert(name, false, "append unexpectedly acquired occupied lock")
  rescue RuntimeError => e
    assert(name, e.message.include?("another session transaction is active"), "wrong occupied-lock diagnostic", e.message)
  end
  assert(name, lock_path.directory?, "occupied lock directory was removed")
  assert(name, lock_path.join("owner.json").read == "occupied\n", "occupied lock owner was modified")
end

with_install do |_root, _home, _install_root, state_root, project|
  name = "FDR cycle append rolls back cycle file when session ledger append fails"
  payload = { "event" => "stop", "thread_id" => "t1" }
  context = StrictModeFdrCycle.context(provider: "codex", payload: payload, cwd: project, project_dir: project)
  cycle_path = StrictModeFdrCycle.cycle_path(state_root, "codex", context.fetch("session_key"))
  ledger_path = StrictModeFdrCycle.ledger_path(state_root, "codex", context.fetch("session_key"))
  ledger_path.mkpath
  begin
    StrictModeFdrCycle.append_cycle!(
      state_root,
      context,
      decision: "skipped-no-turn-text",
      challenge_reason: "no-normalized-turn-text"
    )
    assert(name, false, "append unexpectedly succeeded with ledger path directory")
  rescue RuntimeError => e
    assert(name, e.message.include?("session ledger"), "wrong ledger failure diagnostic", e.message)
  end
  assert(name, !cycle_path.exist?, "cycle file was left behind without ledger coverage")
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop emits semantic judge challenge output"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "stop",
    "thread_id" => "t1",
    "last_assistant_message" => "0 проблем, выглядит чисто.",
    "strict_judge_history" => INITIAL_JUDGE_HISTORY
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider stop contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "semantic judge challenge did not block", stdout)
  assert(name, emitted.fetch("reason").include?("FDR judge challenge"), "semantic judge reason missing prefix", stdout)
  assert(name, emitted.fetch("reason").include?("Где ты схалтурил"), "semantic judge reason missing challenge text", stdout)
  assert(name, stderr.empty?, "provider stop contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root, "stop")
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("emitted") == true, "semantic judge emission not recorded", enforcement.inspect)
  judge = enforcement.fetch("judge")
  assert(name, judge.fetch("attempted") == true, "semantic judge was not attempted", enforcement.inspect)
  assert(name, judge.fetch("verdict") == "challenge", "semantic judge verdict not recorded", enforcement.inspect)
  assert(name, judge.fetch("response_hash").match?(/\A[a-f0-9]{64}\z/), "semantic judge response hash missing", enforcement.inspect)
  cycles = assert_fdr_cycle_and_ledger(name, state_root, ["judge-challenge"])
  cycle = cycles.first
  assert(name, cycle.fetch("challenge_reason") == "judge-reported-challenge", "challenge cycle reason mismatch", cycle.inspect)
  assert(name, cycle.fetch("cycle_index") == 1 && cycle.fetch("max_cycles") == 2, "challenge cycle index mismatch", cycle.inspect)
  assert(name, cycle.fetch("prompt_hash") != StrictModeFdrCycle::ZERO_HASH, "challenge prompt hash missing", cycle.inspect)
  assert(name, cycle.fetch("response_hash") == judge.fetch("response_hash"), "challenge response hash mismatch", cycle.inspect)
  assert(name, !JSON.generate(cycle).include?("0 проблем"), "FDR cycle leaked assistant text", JSON.generate(cycle))
end

template_hash_preinstall = lambda do |_root, _home, install_root, _project|
  config_root = install_root.join("config")
  config_root.mkpath
  config_root.join("judge-prompt-template.md").write("# Custom judge prompt\nReturn judge.response.v1 only.\n")
  File.chmod(0o600, config_root.join("judge-prompt-template.md"))
end
with_install(preinstall: template_hash_preinstall) do |_root, home, install_root, state_root, project|
  name = "enforcing stop FDR prompt hash binds trusted judge-prompt-template"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "stop",
    "thread_id" => "t1",
    "last_assistant_message" => "0 проблем, выглядит чисто.",
    "strict_judge_history" => INITIAL_JUDGE_HISTORY
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider stop contract should control exit code", stdout + stderr)
  assert(name, JSON.parse(stdout).fetch("decision") == "block", "semantic judge challenge did not block", stdout)
  assert(name, stderr.empty?, "provider stop contract should keep stderr empty", stderr)

  cycles = assert_fdr_cycle_and_ledger(name, state_root, ["judge-challenge"])
  cycle = cycles.first
  cycle_context = StrictModeFdrCycle.context(provider: "codex", payload: payload, cwd: project, project_dir: project)
  template_hash = Digest::SHA256.hexdigest("# Custom judge prompt\nReturn judge.response.v1 only.\n")
  expected_prompt_hash = StrictModeFdrCycle.prompt_hash(
    cycle_context,
    judge_backend: cycle.fetch("judge_backend"),
    judge_model: cycle.fetch("judge_model"),
    prompt_template_hash: template_hash
  )
  assert(name, cycle.fetch("prompt_hash") == expected_prompt_hash, "FDR prompt hash did not bind judge template hash", cycle.inspect)
  assert(name, !JSON.generate(cycle).include?("Custom judge prompt"), "FDR cycle leaked judge template text", JSON.generate(cycle))
  reusable = StrictModeFdrCycle.reusable_result(state_root, cycle_context, prompt_template_hash: template_hash)
  assert(name, reusable && reusable.fetch("decision") == "judge-challenge", "matching template hash did not allow challenge reuse", reusable.inspect)
  changed_template_hash = Digest::SHA256.hexdigest("# Different judge prompt\n")
  assert(name, StrictModeFdrCycle.reusable_result(state_root, cycle_context, prompt_template_hash: changed_template_hash).nil?, "changed template hash reused stale challenge", cycle.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop reuses prior semantic judge challenge without a second judge call"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "stop",
    "thread_id" => "t1",
    "last_assistant_message" => "0 проблем, выглядит чисто.",
    "strict_judge_history" => INITIAL_JUDGE_HISTORY
  }
  first_status, first_stdout, first_stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, first_stdout + first_stderr)
  assert(name, first_status.zero?, "first semantic judge challenge should exit through provider contract", first_stdout + first_stderr)

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "reused semantic judge challenge should exit through provider contract", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "reused semantic judge challenge did not block", stdout)
  assert(name, emitted.fetch("reason").include?("reused blocking challenge"), "reused challenge reason missing", stdout)
  assert(name, stderr.empty?, "provider stop contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root, "stop")
  judge = record.fetch("enforcement").fetch("judge")
  assert(name, judge.fetch("attempted") == false, "reused challenge should not invoke semantic judge", judge.inspect)
  assert(name, judge.fetch("verdict") == "challenge" && judge.fetch("reused") == true, "reused challenge summary mismatch", judge.inspect)
  cycles = assert_fdr_cycle_and_ledger(name, state_root, %w[judge-challenge blocked-reused])
  assert(name, cycles[1].fetch("original_challenge_record_hash") == cycles[0].fetch("record_hash"), "blocked-reused did not bind original challenge", cycles.inspect)
  assert(name, cycles[1].fetch("cycle_index") == cycles[0].fetch("cycle_index"), "blocked-reused changed cycle index", cycles.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop reuses last semantic judge challenge after max FDR cycles"
  enable_codex_enforcement!(install_root, state_root)
  payload_for = lambda do |artifact_hash|
    {
      "event" => "stop",
      "thread_id" => "t1",
      "last_assistant_message" => "0 проблем, выглядит чисто.",
      "strict_judge_history" => INITIAL_JUDGE_HISTORY,
      "fdr_artifact" => {
        "artifact_state" => "clean",
        "artifact_hash" => artifact_hash,
        "artifact_verdict" => "clean",
        "finding_count" => 0
      }
    }
  end

  [("a" * 64), ("b" * 64)].each do |artifact_hash|
    status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload_for.call(artifact_hash))
    assert_no_stacktrace(name, stdout + stderr)
    assert(name, status.zero?, "semantic judge challenge should exit through provider contract", stdout + stderr)
    assert(name, JSON.parse(stdout).fetch("decision") == "block", "semantic judge challenge did not block", stdout)
  end

  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload_for.call("c" * 64))
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "max-cycle reused challenge should exit through provider contract", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "max-cycle reused challenge did not block", stdout)
  assert(name, emitted.fetch("reason").include?("reused blocking challenge"), "max-cycle reused challenge reason missing", stdout)
  assert(name, stderr.empty?, "provider stop contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root, "stop")
  judge = record.fetch("enforcement").fetch("judge")
  assert(name, judge.fetch("attempted") == false && judge.fetch("reused") == true, "max-cycle reuse should not invoke semantic judge", judge.inspect)
  cycles = assert_fdr_cycle_and_ledger(name, state_root, %w[judge-challenge judge-challenge blocked-reused])
  assert(name, cycles[0].fetch("cycle_index") == 1 && cycles[1].fetch("cycle_index") == 2, "max-cycle challenge indexes mismatch", cycles.inspect)
  assert(name, cycles[2].fetch("original_challenge_record_hash") == cycles[1].fetch("record_hash"), "max-cycle reuse did not bind last challenge", cycles.inspect)
  assert(name, cycles[2].fetch("cycle_index") == 2, "max-cycle reuse changed original cycle index", cycles.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop allows semantic judge clean response"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "stop",
    "thread_id" => "t1",
    "last_assistant_message" => "Схалтурил: не переписал старый README. Это вне текущего scope и будет follow-up PR.",
    "strict_judge_history" => POST_FIRST_JUDGE_HISTORY
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "semantic judge clean stop should exit cleanly", stdout + stderr)
  assert(name, stdout.empty?, "semantic judge clean should not emit block", stdout)
  assert(name, stderr.empty?, "semantic judge clean should not warn", stderr)

  record = last_discovery_record(state_root, "stop")
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true, "semantic judge clean did not stay enforcing", enforcement.inspect)
  assert(name, enforcement.fetch("emitted") == false, "semantic judge clean emitted a block", enforcement.inspect)
  judge = enforcement.fetch("judge")
  assert(name, judge.fetch("attempted") == true, "semantic judge clean was not attempted", enforcement.inspect)
  assert(name, judge.fetch("verdict") == "clean", "semantic judge clean verdict not recorded", enforcement.inspect)
  cycles = assert_fdr_cycle_and_ledger(name, state_root, ["judge-clean"])
  cycle = cycles.first
  assert(name, cycle.fetch("challenge_reason") == "judge-clean", "clean cycle reason mismatch", cycle.inspect)
  assert(name, cycle.fetch("cycle_index") == 0, "clean cycle index mismatch", cycle.inspect)
  assert(name, cycle.fetch("prompt_hash") != StrictModeFdrCycle::ZERO_HASH, "clean prompt hash missing", cycle.inspect)
  assert(name, cycle.fetch("response_hash") == judge.fetch("response_hash"), "clean response hash mismatch", cycle.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop allows provider follow-up when stop_hook_active is true"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "event" => "stop",
    "thread_id" => "t1",
    "stop_hook_active" => true,
    "last_assistant_message" => "0 проблем, выглядит чисто.",
    "strict_judge_history" => INITIAL_JUDGE_HISTORY
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "follow-up stop should exit cleanly", stdout + stderr)
  assert(name, stdout.empty?, "follow-up stop should not emit a second block", stdout)
  assert(name, stderr.empty?, "follow-up stop should not warn", stderr)

  record = last_discovery_record(state_root, "stop")
  assert(name, record.fetch("mode") == "enforcing", "follow-up stop record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true, "follow-up stop enforcement not active", enforcement.inspect)
  assert(name, enforcement.fetch("emitted") == false, "follow-up stop emitted a recursive block", enforcement.inspect)
  assert(name, enforcement.fetch("failed_closed") == false, "follow-up stop failed closed", enforcement.inspect)
  assert(name, enforcement.fetch("stop_hook_active") == true, "follow-up stop was not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.stop.block", "wrong follow-up stop output contract", enforcement.inspect)
  assert(name, !enforcement.key?("judge"), "follow-up stop should not invoke semantic judge", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop ignores stop_hook_active from provider-mismatched payload"
  enable_codex_enforcement!(install_root, state_root)
  payload = {
    "hook_event_name" => "SubagentStop",
    "transcript_path" => "/tmp/.claude/session.jsonl",
    "stop_hook_active" => true
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider stop contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "provider-mismatched stop should still block", stdout)
  assert(name, emitted.fetch("reason").include?("stop guard"), "provider-mismatched stop reason missing guard reason", stdout)
  assert(name, stderr.include?("provider mismatch"), "provider mismatch was not surfaced", stderr)

  record = last_discovery_record(state_root, "stop")
  assert(name, record.fetch("provider_detection_decision") == "mismatch", "payload was not provider-mismatched", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("emitted") == true, "provider-mismatched stop did not enforce", enforcement.inspect)
  assert(name, enforcement.fetch("stop_hook_active") == false, "provider-mismatched stop_hook_active was trusted", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop follow-up allows after protected-context fail-closed"
  enable_codex_enforcement!(install_root, state_root)
  install_root.join("install-manifest.json").write("{ malformed json\n")
  state_root.join("protected-install-baseline.json").write("{ malformed json\n")

  payload = {
    "event" => "stop",
    "thread_id" => "t1",
    "stop_hook_active" => true
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "follow-up stop should exit cleanly", stdout + stderr)
  assert(name, stdout.empty?, "follow-up stop after fail-closed should not emit a second block", stdout)
  assert(name, stderr.empty?, "follow-up stop after fail-closed should not warn", stderr)

  record = last_discovery_record(state_root, "stop")
  assert(name, record.fetch("mode") == "enforcing", "fail-closed follow-up record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true, "fail-closed follow-up enforcement not active", enforcement.inspect)
  assert(name, enforcement.fetch("emitted") == false, "fail-closed follow-up emitted a recursive block", enforcement.inspect)
  assert(name, enforcement.fetch("failed_closed") == false, "fail-closed follow-up still failed closed", enforcement.inspect)
  assert(name, enforcement.fetch("stop_hook_active") == true, "fail-closed follow-up stop was not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.stop.block", "wrong fail-closed follow-up output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool fails closed on protected baseline tamper"
  enable_codex_enforcement!(install_root, state_root)
  manifest_path = install_root.join("install-manifest.json")
  manifest = read_json(manifest_path)
  manifest["package_version"] = "tampered"
  manifest_path.write(JSON.pretty_generate(manifest) + "\n")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "touch \"#{install_root.join('config/runtime.env')}\""
    }
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "tampered enforcing hook did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected context is untrusted"), "missing protected-context reason", stdout)
  assert(name, stderr.empty?, "provider block contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root)
  assert(name, record.fetch("mode") == "enforcing", "tampered enforcing record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("failed_closed") == true, "fail-closed enforcement not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.pre-tool-use.block", "wrong fail-closed output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool fails closed when tampered baseline removes hook entries"
  enable_codex_enforcement!(install_root, state_root)
  baseline_path = state_root.join("protected-install-baseline.json")
  baseline = read_json(baseline_path)
  baseline["managed_hook_entries"] = []
  baseline_path.write(JSON.pretty_generate(baseline) + "\n")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "echo ok"
    }
  }
  status, stdout, stderr = run_hook_capture(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "tampered baseline did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected context is untrusted"), "missing protected-context reason", stdout)
  assert(name, stderr.empty?, "provider block contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root)
  assert(name, record.fetch("mode") == "enforcing", "tampered baseline record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("failed_closed") == true, "fail-closed enforcement not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.pre-tool-use.block", "wrong fail-closed output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool fails closed on malformed install manifest"
  enable_codex_enforcement!(install_root, state_root)
  install_root.join("install-manifest.json").write("{ malformed json\n")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "echo ok"
    }
  }
  status, stdout, stderr = run_hook_capture(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "malformed manifest did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected context is untrusted"), "missing protected-context reason", stdout)
  assert(name, stderr.empty?, "provider block contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root)
  assert(name, record.fetch("mode") == "enforcing", "malformed manifest record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("failed_closed") == true, "fail-closed enforcement not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.pre-tool-use.block", "wrong fail-closed output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool fails closed on malformed protected baseline"
  enable_codex_enforcement!(install_root, state_root)
  state_root.join("protected-install-baseline.json").write("{ malformed json\n")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "echo ok"
    }
  }
  status, stdout, stderr = run_hook_capture(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "malformed baseline did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected context is untrusted"), "missing protected-context reason", stdout)
  assert(name, stderr.empty?, "provider block contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root)
  assert(name, record.fetch("mode") == "enforcing", "malformed baseline record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("failed_closed") == true, "fail-closed enforcement not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.pre-tool-use.block", "wrong fail-closed output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool fails closed when manifest and protected baseline are both malformed"
  enable_codex_enforcement!(install_root, state_root)
  install_root.join("install-manifest.json").write("{ malformed json\n")
  state_root.join("protected-install-baseline.json").write("{ malformed json\n")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "echo ok"
    }
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider block contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "malformed manifest/baseline did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected context is untrusted"), "missing protected-context reason", stdout)
  assert(name, stderr.empty?, "provider block contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root)
  assert(name, record.fetch("mode") == "enforcing", "malformed manifest/baseline record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("failed_closed") == true, "fail-closed enforcement not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.pre-tool-use.block", "wrong fail-closed output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing stop fails closed when manifest and protected baseline are both malformed"
  enable_codex_enforcement!(install_root, state_root)
  install_root.join("install-manifest.json").write("{ malformed json\n")
  state_root.join("protected-install-baseline.json").write("{ malformed json\n")

  payload = {
    "event" => "stop",
    "thread_id" => "t1"
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "stop", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "provider stop contract should control exit code", stdout + stderr)
  emitted = JSON.parse(stdout)
  assert(name, emitted.fetch("decision") == "block", "malformed manifest/baseline stop did not block", stdout)
  assert(name, emitted.fetch("reason").include?("protected context is untrusted"), "missing protected-context reason", stdout)
  assert(name, stderr.empty?, "provider stop contract should keep stderr empty", stderr)

  record = last_discovery_record(state_root, "stop")
  assert(name, record.fetch("mode") == "enforcing", "malformed manifest/baseline stop record did not stay enforcing", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("failed_closed") == true, "fail-closed stop enforcement not recorded", enforcement.inspect)
  assert(name, enforcement.fetch("output_contract_id") == "codex.stop.block", "wrong stop fail-closed output contract", enforcement.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool preflight logs protected shell block without enforcing"
  command = "touch \"#{install_root.join('config/runtime.env')}\""
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => command
    }
  }
  status, output = run_hook(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, output)
  assert(name, status.zero?, "strict-hook must stay discovery/log-only", output)
  assert(name, output.include?("preflight would block"), "missing would-block warning", output)

  record = last_discovery_record(state_root)
  preflight = record.fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("schema_version") == 1, "preflight schema version missing", preflight.inspect)
  assert(name, preflight.fetch("preflight_hash").match?(/\A[a-f0-9]{64}\z/), "preflight hash missing", preflight.inspect)
  assert(name, preflight.fetch("attempted") == true, "preflight was not attempted")
  assert(name, preflight.fetch("trusted") == true, "preflight was not trusted", preflight.inspect)
  assert(name, preflight.fetch("decision") == "block", "preflight did not classify block", preflight.inspect)
  assert(name, preflight.fetch("would_block") == true, "preflight would_block mismatch", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "protected-root", "wrong reason_code", preflight.inspect)
  assert(name, preflight.fetch("tool_kind") == "shell", "exec_command was not normalized as shell", preflight.inspect)
  assert(name, preflight.fetch("command_hash") == Digest::SHA256.hexdigest(command), "command hash mismatch", preflight.inspect)
  assert(name, !state_root.join("discovery/codex-pre-tool-use.jsonl").read.include?(command), "raw shell command leaked into discovery log")
  assert(name, record.fetch("trusted_state_written") == false, "preflight wrote trusted state")
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool preflight blocks runtime command substitution without enforcing"
  escaped_hook = install_root.join("active/bin/strict-hook").to_s.gsub(" ", "\\ ")
  command = "echo $(#{escaped_hook} --provider codex stop)"
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => command
    }
  }
  status, output = run_hook(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, output)
  assert(name, status.zero?, "strict-hook must stay discovery/log-only", output)
  assert(name, output.include?("preflight would block"), "missing would-block warning", output)

  record = last_discovery_record(state_root)
  preflight = record.fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("trusted") == true, "preflight was not trusted", preflight.inspect)
  assert(name, preflight.fetch("decision") == "block", "preflight did not classify block", preflight.inspect)
  assert(name, preflight.fetch("would_block") == true, "preflight would_block mismatch", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "protected-runtime-execution", "wrong reason_code", preflight.inspect)
  assert(name, preflight.fetch("command_hash") == Digest::SHA256.hexdigest(command), "command hash mismatch", preflight.inspect)
  assert(name, !state_root.join("discovery/codex-pre-tool-use.jsonl").read.include?(command), "raw shell command leaked into discovery log")
  assert(name, record.fetch("trusted_state_written") == false, "preflight wrote trusted state")
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool preflight allows exact strict-fdr import in discovery without trusted state"
  project.join("review.md").write("# review\n\n```json strict-fdr-v1\n#{JSON.pretty_generate({
    "review_generated_at" => "2026-05-13T00:00:00Z",
    "reviewer" => "fixture-reviewer",
    "verdict" => "clean",
    "findings" => []
  })}\n```\n")
  command = "\"#{install_root.join('active/bin/strict-fdr')}\" import -- review.md"
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => command
    }
  }
  status, output = run_hook(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, output)
  assert(name, status.zero?, "strict-hook must stay discovery/log-only", output)
  assert(name, !output.include?("preflight would block"), "exact import should not warn as would-block", output)

  record = last_discovery_record(state_root)
  preflight = record.fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("trusted") == true, "preflight was not trusted", preflight.inspect)
  assert(name, preflight.fetch("decision") == "allow", "preflight did not classify allow", preflight.inspect)
  assert(name, preflight.fetch("would_block") == false, "preflight would_block mismatch", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "trusted-import-ready", "wrong reason_code", preflight.inspect)
  assert(name, preflight.fetch("command_hash") == Digest::SHA256.hexdigest(command), "command hash mismatch", preflight.inspect)
  assert(name, !state_root.join("discovery/codex-pre-tool-use.jsonl").read.include?(command), "raw shell command leaked into discovery log")
  assert(name, record.fetch("trusted_state_written") == false, "preflight wrote trusted state")
end

with_install do |_root, home, install_root, state_root, project|
  name = "enforcing pre-tool records trusted strict-fdr import intent"
  enable_codex_enforcement!(install_root, state_root)
  project.join("review.md").write("# review\n\n```json strict-fdr-v1\n#{JSON.pretty_generate({
    "review_generated_at" => "2026-05-13T00:00:00Z",
    "reviewer" => "fixture-reviewer",
    "verdict" => "clean",
    "findings" => []
  })}\n```\n")
  command = "\"#{install_root.join('active/bin/strict-fdr')}\" import -- review.md"
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => command
    }
  }
  status, stdout, stderr = run_enforcing_hook_event_capture(home, install_root, state_root, project, "pre-tool-use", payload)
  assert_no_stacktrace(name, stdout + stderr)
  assert(name, status.zero?, "trusted import pre-tool should exit cleanly", stdout + stderr)
  assert(name, stdout.empty? && stderr.empty?, "trusted import pre-tool should not emit provider output", stdout + stderr)

  record = last_discovery_record(state_root)
  preflight = record.fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("decision") == "allow", "preflight did not allow exact import", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "trusted-import-ready", "wrong reason_code", preflight.inspect)
  assert(name, record.fetch("trusted_state_written") == true, "trusted import intent was not recorded", record.inspect)
  enforcement = record.fetch("enforcement")
  assert(name, enforcement.fetch("active") == true && enforcement.fetch("emitted") == false, "enforcement should allow trusted import command", enforcement.inspect)

  identity = fdr_session_identity("t1")
  intent_path = StrictModeFdrImport.tool_intent_log_path(state_root, "codex", identity.fetch("session_key"))
  assert(name, intent_path.file?, "tool intent log missing")
  intent = JSON.parse(intent_path.read.lines.last)
  assert(name, intent.fetch("command_hash_source") == "trusted-import-argv", "intent command hash source mismatch", intent.inspect)
  assert(name, intent.fetch("normalized_path_list") == [project.join("review.md").realpath.to_s], "intent path binding mismatch", intent.inspect)
  ledgers = fdr_ledger_records(state_root)
  assert(name, StrictModeFdrCycle.validate_session_ledger_chain(fdr_ledger_path(state_root)).empty?, "session ledger invalid", ledgers.inspect)
  assert(name, ledgers.last.fetch("writer") == "strict-hook" && ledgers.last.fetch("target_class") == "tool-intent-log", "intent ledger tuple mismatch", ledgers.inspect)
  assert(name, ledgers.last.fetch("related_record_hash") == intent.fetch("intent_hash"), "intent ledger hash mismatch", ledgers.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool preflight blocks patch move into protected root"
  destination = install_root.join("config/runtime.env")
  patch = "*** Begin Patch\n*** Update File: lib/safe.rb\n*** Move to: #{destination}\n@@\n-old\n+new\n*** End Patch\n"
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "apply_patch",
    "tool_input" => {
      "patch" => patch
    }
  }
  status, output = run_hook(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, output)
  assert(name, status.zero?, "strict-hook must stay discovery/log-only", output)
  assert(name, output.include?("preflight would block"), "missing would-block warning", output)

  record = last_discovery_record(state_root)
  preflight = record.fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("trusted") == true, "preflight was not trusted", preflight.inspect)
  assert(name, preflight.fetch("decision") == "block", "preflight did not classify block", preflight.inspect)
  assert(name, preflight.fetch("would_block") == true, "preflight would_block mismatch", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "protected-root", "wrong reason_code", preflight.inspect)
  assert(name, preflight.fetch("tool_kind") == "patch", "apply_patch was not normalized as patch", preflight.inspect)
  assert(name, !state_root.join("discovery/codex-pre-tool-use.jsonl").read.include?(destination.to_s), "raw protected destination leaked into discovery log")
  assert(name, record.fetch("trusted_state_written") == false, "preflight wrote trusted state")
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool preflight logs safe read-only shell allow"
  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "ls -la ."
    }
  }
  status, output = run_hook(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, output)
  assert(name, status.zero?, "strict-hook failed", output)

  preflight = last_discovery_record(state_root).fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("trusted") == true, "preflight was not trusted", preflight.inspect)
  assert(name, preflight.fetch("decision") == "allow", "safe shell did not allow", preflight.inspect)
  assert(name, preflight.fetch("would_block") == false, "safe shell would_block mismatch", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "shell-read-only-or-unmatched", "wrong allow reason", preflight.inspect)
end

with_install do |_root, home, install_root, state_root, project|
  name = "pre-tool preflight reports untrusted protected baseline without enforcing"
  manifest_path = install_root.join("install-manifest.json")
  manifest = read_json(manifest_path)
  manifest["package_version"] = "tampered"
  manifest_path.write(JSON.pretty_generate(manifest) + "\n")

  payload = {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "touch \"#{install_root.join('config/runtime.env')}\""
    }
  }
  status, output = run_hook(home, install_root, state_root, project, payload)
  assert_no_stacktrace(name, output)
  assert(name, status.zero?, "strict-hook must stay discovery/log-only on baseline tamper", output)

  preflight = last_discovery_record(state_root).fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("attempted") == true, "preflight was not attempted")
  assert(name, preflight.fetch("trusted") == false, "tampered baseline preflight loaded trusted", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "protected-baseline-untrusted", "wrong untrusted reason", preflight.inspect)
  assert(name, preflight.fetch("error_count") > 0, "baseline error count missing", preflight.inspect)
  assert(name, preflight.fetch("error_hash").match?(/\A[a-f0-9]{64}\z/), "baseline error hash invalid", preflight.inspect)
end

if $failures.empty?
  puts "hook preflight tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
