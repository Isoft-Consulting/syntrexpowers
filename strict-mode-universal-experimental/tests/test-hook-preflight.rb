#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../tools/metadata_lib"
require_relative "../tools/preflight_record_lib"

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

def last_discovery_record(state_root)
  log = state_root.join("discovery/codex-pre-tool-use.jsonl")
  raise "#{log}: missing discovery log" unless log.file?

  JSON.parse(log.read.lines.last)
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
