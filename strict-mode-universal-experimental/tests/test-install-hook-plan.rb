#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require_relative "../tools/install_hook_plan_lib"

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def selected_output(provider, logical_event, contract_id, provider_action: "block")
  {
    "provider" => provider,
    "provider_version" => "unknown",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => logical_event,
    "logical_event" => logical_event,
    "contract_kind" => "decision-output",
    "contract_id" => contract_id,
    "provider_action" => provider_action,
    "decision_contract_hash" => "a" * 64,
    "fixture_record_hash" => "b" * 64,
    "fixture_manifest_hash" => "c" * 64
  }
end

def run_case
  $cases += 1
  yield
rescue RuntimeError, ArgumentError, KeyError => e
  record_failure("case #{$cases}", "unexpected exception: #{e.class}: #{e.message}", e.backtrace&.first.to_s)
end

run_case do
  name = "discovery Codex hook plan excludes PermissionRequest without selected output proof"
  entries = StrictModeInstallHookPlan.managed_entries("codex", Pathname.new("/tmp/codex-hooks.json"), Pathname.new("/tmp/strict root"))
  assert(name, entries.size == 5, "unexpected discovery hook count", entries.inspect)
  assert(name, entries.none? { |entry| entry.fetch("hook_event") == "PermissionRequest" }, "PermissionRequest installed without proof", entries.inspect)
  assert(name, entries.all? { |entry| entry.fetch("enforcing") == false && entry.fetch("output_contract_id") == "" }, "discovery entries claimed enforcement", entries.inspect)
  assert(name, entries.all? { |entry| entry.fetch("command").include?("STRICT_STATE_ROOT=\"/tmp/strict root/state\"") }, "commands do not bind default state root", entries.inspect)
end

run_case do
  name = "discovery hook plan binds custom state root in command"
  entries = StrictModeInstallHookPlan.managed_entries(
    "codex",
    Pathname.new("/tmp/codex-hooks.json"),
    Pathname.new("/tmp/strict root"),
    state_root: Pathname.new("/tmp/strict state")
  )
  errors = StrictModeHookEntryPlan.validate(entries, selected_output_contracts: [], enforce: false, install_root: "/tmp/strict root", state_root: "/tmp/strict state")
  assert(name, errors.empty?, "custom state-root entries failed validation", errors.join("\n"))
  assert(name, entries.all? { |entry| entry.fetch("command").include?("STRICT_STATE_ROOT=\"/tmp/strict state\"") }, "commands do not bind custom state root", entries.inspect)
end

run_case do
  name = "enforcing Codex hook plan adds PermissionRequest only from selected output proof"
  selected = [
    selected_output("codex", "pre-tool-use", "codex.pre-tool-use.block"),
    selected_output("codex", "stop", "codex.stop.block"),
    selected_output("codex", "permission-request", "codex.permission-request.deny", provider_action: "deny")
  ]
  entries = StrictModeInstallHookPlan.managed_entries(
    "codex",
    Pathname.new("/tmp/codex-hooks.json"),
    Pathname.new("/tmp/strict root"),
    selected_output_contracts: selected,
    enforce: true
  )
  permission = entries.find { |entry| entry.fetch("logical_event") == "permission-request" }
  assert(name, entries.size == 6, "unexpected enforcing hook count", entries.inspect)
  assert(name, permission, "missing PermissionRequest entry", entries.inspect)
  assert(name, permission.fetch("hook_event") == "PermissionRequest", "wrong provider event", permission.inspect)
  assert(name, permission.fetch("matcher") == ".*", "wrong PermissionRequest matcher", permission.inspect)
  assert(name, permission.fetch("enforcing") == true && permission.fetch("output_contract_id") == "codex.permission-request.deny", "PermissionRequest output contract not bound", permission.inspect)
end

run_case do
  name = "malformed selected output cannot enable conditional PermissionRequest"
  malformed = [{ "provider" => "codex", "logical_event" => "permission-request" }]
  begin
    StrictModeInstallHookPlan.managed_entries(
      "codex",
      Pathname.new("/tmp/codex-hooks.json"),
      Pathname.new("/tmp/strict root"),
      selected_output_contracts: malformed
    )
    record_failure(name, "expected malformed selected output rejection")
  rescue RuntimeError => e
    assert(name, e.message.include?("selected output contract 0: missing fields"), "wrong rejection", e.message)
  end
end

run_case do
  name = "hook config entry projects matcher and provider timeout exactly"
  entry = StrictModeInstallHookPlan.managed_entries("claude", Pathname.new("/tmp/claude.json"), Pathname.new("/tmp/strict root")).
    find { |candidate| candidate.fetch("logical_event") == "pre-tool-use" }
  config_entry = StrictModeInstallHookPlan.hook_config_entry(entry)
  hook = config_entry.fetch("hooks").fetch(0)
  assert(name, config_entry.fetch("matcher") == ".*", "matcher missing", config_entry.inspect)
  assert(name, hook.fetch("timeout") == 6_000, "Claude provider timeout missing", config_entry.inspect)
  assert(name, hook.fetch("command").include?("\"/tmp/strict root/active/bin/strict-hook\""), "command path not shell quoted", config_entry.inspect)
end

if $failures.empty?
  puts "install hook plan tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
