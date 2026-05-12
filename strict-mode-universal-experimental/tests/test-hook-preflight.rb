#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../tools/decision_contract_lib"
require_relative "../tools/fixture_readiness_lib"
require_relative "../tools/hook_entry_plan_lib"
require_relative "../tools/metadata_lib"
require_relative "../tools/preflight_record_lib"
require_relative "../tools/protected_baseline_lib"

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

def decision_output_fixture_record(root, event)
  provider = "codex"
  contract_id = "codex.#{event}.block"
  metadata = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "event" => event,
    "logical_event" => event,
    "provider_action" => "block",
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
  stdout_path = fixture_file(root, provider, "decision-output/#{event}/#{contract_id}.stdout", "{\"decision\":\"block\",\"reason\":\"blocked\"}\n")
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

def enable_codex_enforcement!(install_root, state_root)
  active_root = Pathname.new(install_root.join("active").realpath)
  write_fixture_manifest(active_root, "codex", %w[pre-tool-use stop].map { |event| decision_output_fixture_record(active_root, event) })
  selected = StrictModeFixtureReadiness.selected_output_contracts(active_root, ["codex"])

  manifest_path = install_root.join("install-manifest.json")
  baseline_path = state_root.join("protected-install-baseline.json")
  manifest = read_json(manifest_path)
  baseline = read_json(baseline_path)
  entries = StrictModeHookEntryPlan.apply(
    manifest.fetch("managed_hook_entries"),
    selected_output_contracts: selected,
    enforce: true,
    install_root: install_root.to_s,
    state_root: state_root.to_s
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

def with_install
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
    "stop" => "codex.stop.block"
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
  name = "pre-tool preflight blocks strict-fdr import while importer is unavailable"
  project.join("review.md").write("# review\n")
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
  assert(name, output.include?("preflight would block"), "missing would-block warning", output)

  record = last_discovery_record(state_root)
  preflight = record.fetch("preflight")
  assert_valid_preflight(name, preflight)
  assert(name, preflight.fetch("trusted") == true, "preflight was not trusted", preflight.inspect)
  assert(name, preflight.fetch("decision") == "block", "preflight did not classify block", preflight.inspect)
  assert(name, preflight.fetch("would_block") == true, "preflight would_block mismatch", preflight.inspect)
  assert(name, preflight.fetch("reason_code") == "trusted-import-unavailable", "wrong reason_code", preflight.inspect)
  assert(name, preflight.fetch("command_hash") == Digest::SHA256.hexdigest(command), "command hash mismatch", preflight.inspect)
  assert(name, !state_root.join("discovery/codex-pre-tool-use.jsonl").read.include?(command), "raw shell command leaked into discovery log")
  assert(name, record.fetch("trusted_state_written") == false, "preflight wrote trusted state")
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
