#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../tools/hook_entry_plan_lib"

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def hook_event_for(logical_event)
  {
    "session-start" => "SessionStart",
    "user-prompt-submit" => "UserPromptSubmit",
    "pre-tool-use" => "PreToolUse",
    "post-tool-use" => "PostToolUse",
    "stop" => "Stop",
    "permission-request" => "PermissionRequest"
  }.fetch(logical_event)
end

def entry_for(provider, logical_event, output_contract_id: "", enforcing: false, matcher: "")
  hook_event = hook_event_for(logical_event)
  matcher = ".*" if matcher.empty? && %w[pre-tool-use post-tool-use permission-request].include?(logical_event)
  command = "STRICT_HOOK_TIMEOUT_MS=5000 STRICT_STATE_ROOT=\"/tmp/strict state\" \"/tmp/strict root/active/bin/strict-hook\" --provider #{provider} #{logical_event}"
  entry = {
    "provider" => provider,
    "provider_version" => "unknown",
    "config_path" => "/tmp/#{provider}.json",
    "hook_event" => hook_event,
    "logical_event" => logical_event,
    "matcher" => matcher,
    "command" => command,
    "provider_env" => {},
    "self_timeout_ms" => 5_000,
    "provider_timeout_ms" => provider == "claude" ? 6_000 : 0,
    "provider_timeout_field" => provider == "claude" ? "timeout" : "",
    "output_contract_id" => output_contract_id,
    "enforcing" => enforcing,
    "removal_selector" => {}
  }
  entry["removal_selector"] = StrictModeHookEntryPlan.removal_selector_for(entry)
  entry
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
  name = "discovery plan clears stale enforcement fields without selected-output dependency"
  original = [
    entry_for("codex", "pre-tool-use", output_contract_id: "stale.pre", enforcing: true),
    entry_for("codex", "post-tool-use", output_contract_id: "stale.post", enforcing: true)
  ]
  planned = StrictModeHookEntryPlan.apply(
    original,
    selected_output_contracts: [selected_output("codex", "pre-tool-use", "codex.pre.block")],
    enforce: false
  )
  assert(name, planned.all? { |entry| entry.fetch("enforcing") == false }, "discovery entries must not enforce", planned.inspect)
  assert(name, planned.all? { |entry| entry.fetch("output_contract_id") == "" }, "discovery entries must not carry output contracts", planned.inspect)
  assert(name, original.first.fetch("enforcing") == true && original.first.fetch("output_contract_id") == "stale.pre", "planner mutated caller-owned entries")
end

run_case do
  name = "enforcing plan binds blocking entries and leaves non-blocking entries discovery-only"
  entries = [
    entry_for("codex", "pre-tool-use"),
    entry_for("codex", "post-tool-use"),
    entry_for("codex", "stop"),
    entry_for("codex", "permission-request")
  ]
  selected = [
    selected_output("codex", "pre-tool-use", "codex.pre.block"),
    selected_output("codex", "stop", "codex.stop.block", provider_action: "block"),
    selected_output("codex", "permission-request", "codex.permission.deny", provider_action: "deny")
  ]
  planned = StrictModeHookEntryPlan.apply(entries, selected_output_contracts: selected, enforce: true)
  pre = planned.find { |entry| entry.fetch("logical_event") == "pre-tool-use" }
  post = planned.find { |entry| entry.fetch("logical_event") == "post-tool-use" }
  stop = planned.find { |entry| entry.fetch("logical_event") == "stop" }
  permission = planned.find { |entry| entry.fetch("logical_event") == "permission-request" }
  assert(name, pre.fetch("enforcing") == true && pre.fetch("output_contract_id") == "codex.pre.block", "pre-tool-use binding mismatch", planned.inspect)
  assert(name, stop.fetch("enforcing") == true && stop.fetch("output_contract_id") == "codex.stop.block", "stop binding mismatch", planned.inspect)
  assert(name, permission.fetch("enforcing") == true && permission.fetch("output_contract_id") == "codex.permission.deny", "permission-request binding mismatch", planned.inspect)
  assert(name, post.fetch("enforcing") == false && post.fetch("output_contract_id") == "", "post-tool-use must stay non-blocking", planned.inspect)
  errors = StrictModeHookEntryPlan.validate(planned, selected_output_contracts: selected, enforce: true)
  assert(name, errors.empty?, "planned entries failed validation", errors.join("\n"))
end

run_case do
  name = "enforcing plan rejects missing selected output contract"
  entries = [entry_for("codex", "pre-tool-use"), entry_for("codex", "stop")]
  selected = [selected_output("codex", "pre-tool-use", "codex.pre.block")]
  begin
    StrictModeHookEntryPlan.apply(entries, selected_output_contracts: selected, enforce: true)
    record_failure(name, "expected missing selected contract rejection")
  rescue RuntimeError => e
    assert(name, e.message.include?("missing selected output contract for codex stop"), "wrong rejection", e.message)
  end
end

run_case do
  name = "selected output contracts reject duplicate provider event tuples"
  selected = [
    selected_output("codex", "pre-tool-use", "codex.pre.block"),
    selected_output("codex", "pre-tool-use", "codex.pre.deny", provider_action: "deny")
  ]
  errors = StrictModeHookEntryPlan.selected_output_contract_errors(selected)
  assert(name, errors.any? { |error| error.include?("duplicate provider/logical_event tuple") }, "missing duplicate tuple diagnostic", errors.join("\n"))
end

run_case do
  name = "selected output contracts reject effectless provider actions"
  bad = selected_output("codex", "stop", "codex.stop.warn")
  bad["provider_action"] = "warn"
  errors = StrictModeHookEntryPlan.selected_output_contract_errors([bad])
  assert(name, errors.any? { |error| error.include?("provider_action must be block for stop and subagent-stop or block/deny") }, "missing provider_action diagnostic", errors.join("\n"))
end

run_case do
  name = "selected output contracts reject stop deny actions"
  bad = selected_output("codex", "stop", "codex.stop.deny", provider_action: "deny")
  errors = StrictModeHookEntryPlan.selected_output_contract_errors([bad])
  assert(name, errors.any? { |error| error.include?("provider_action must be block for stop and subagent-stop or block/deny") }, "missing stop provider_action diagnostic", errors.join("\n"))
end

run_case do
  name = "selected output contracts reject malformed identity fields"
  bad = selected_output("codex", "stop", "codex.stop.block")
  bad["provider_version"] = ""
  bad["platform"] = 7
  bad["fixture_record_hash"] = "bad"
  errors = StrictModeHookEntryPlan.selected_output_contract_errors([bad])
  assert(name, errors.any? { |error| error.include?("provider_version must be non-empty") }, "missing provider_version diagnostic", errors.join("\n"))
  assert(name, errors.any? { |error| error.include?("platform must be a string") }, "missing platform type diagnostic", errors.join("\n"))
  assert(name, errors.any? { |error| error.include?("fixture_record_hash must be lowercase SHA-256") }, "missing fixture hash diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects managed hook command not using lexical active strict-hook"
  entry = entry_for("codex", "stop")
  entry["command"] = "STRICT_HOOK_TIMEOUT_MS=5000 STRICT_STATE_ROOT=\"/tmp/strict state\" \"/tmp/strict root/releases/tx/bin/strict-hook\" --provider codex stop"
  entry["removal_selector"] = StrictModeHookEntryPlan.removal_selector_for(entry)
  errors = StrictModeHookEntryPlan.validate([entry], selected_output_contracts: [], enforce: false)
  assert(name, errors.any? { |error| error.include?("must end with /active/bin/strict-hook") }, "missing lexical active path diagnostic", errors.join("\n"))
  assert(name, errors.any? { |error| error.include?("must not target a release realpath") }, "missing release path diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects managed hook command provider and event drift"
  entry = entry_for("codex", "pre-tool-use")
  entry["command"] = "STRICT_HOOK_TIMEOUT_MS=5000 STRICT_STATE_ROOT=\"/tmp/strict state\" \"/tmp/strict root/active/bin/strict-hook\" --provider claude stop"
  entry["removal_selector"] = StrictModeHookEntryPlan.removal_selector_for(entry)
  errors = StrictModeHookEntryPlan.validate([entry], selected_output_contracts: [], enforce: false)
  assert(name, errors.any? { |error| error.include?("command provider argv mismatch") }, "missing provider argv diagnostic", errors.join("\n"))
  assert(name, errors.any? { |error| error.include?("command logical_event argv mismatch") }, "missing logical_event argv diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects managed hook command outside install root when install root is known"
  entry = entry_for("codex", "stop")
  errors = StrictModeHookEntryPlan.validate([entry], selected_output_contracts: [], enforce: false, install_root: "/other/strict root")
  assert(name, errors.any? { |error| error.include?("command hook path must match install_root active strict-hook") }, "missing install-root command path diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects managed hook command outside state root when state root is known"
  entry = entry_for("codex", "stop")
  errors = StrictModeHookEntryPlan.validate([entry], selected_output_contracts: [], enforce: false, state_root: "/other/strict state")
  assert(name, errors.any? { |error| error.include?("command state root must match state_root") }, "missing state-root command diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects shell wrapper or extra managed hook command argv"
  entry = entry_for("codex", "stop")
  entry["command"] = "STRICT_HOOK_TIMEOUT_MS=5000 STRICT_STATE_ROOT=\"/tmp/strict state\" \"/tmp/strict root/active/bin/strict-hook\" --provider codex stop && echo bypass"
  entry["removal_selector"] = StrictModeHookEntryPlan.removal_selector_for(entry)
  errors = StrictModeHookEntryPlan.validate([entry], selected_output_contracts: [], enforce: false)
  assert(name, errors.any? { |error| error.include?("command must be STRICT_HOOK_TIMEOUT_MS") }, "missing command shape diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects unquoted managed hook command paths"
  entry = entry_for("codex", "stop", output_contract_id: "codex.stop.block", enforcing: true)
  entry["command"] = "STRICT_HOOK_TIMEOUT_MS=5000 STRICT_STATE_ROOT=/tmp/strict-state STRICT_ENFORCING_HOOK=1 STRICT_OUTPUT_CONTRACT_ID=codex.stop.block /tmp/strict-root/active/bin/strict-hook --provider codex stop"
  entry["removal_selector"] = StrictModeHookEntryPlan.removal_selector_for(entry)
  errors = StrictModeHookEntryPlan.validate(
    [entry],
    selected_output_contracts: [selected_output("codex", "stop", "codex.stop.block")],
    enforce: true,
    install_root: "/tmp/strict-root",
    state_root: "/tmp/strict-state"
  )
  assert(name, errors.any? { |error| error.include?("command must be STRICT_HOOK_TIMEOUT_MS") }, "missing unquoted command shape diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects enforcing hook with wrong output contract id"
  selected = [
    selected_output("codex", "pre-tool-use", "codex.pre.block"),
    selected_output("codex", "stop", "codex.stop.block")
  ]
  planned = StrictModeHookEntryPlan.apply([entry_for("codex", "pre-tool-use"), entry_for("codex", "stop")], selected_output_contracts: selected, enforce: true)
  planned.first["output_contract_id"] = "wrong"
  errors = StrictModeHookEntryPlan.validate(planned, selected_output_contracts: selected, enforce: true)
  assert(name, errors.any? { |error| error.include?("output_contract_id must be codex.pre.block") }, "missing wrong-id diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects duplicate removal selectors"
  entries = [entry_for("claude", "stop"), entry_for("claude", "stop")]
  errors = StrictModeHookEntryPlan.validate(entries, selected_output_contracts: [], enforce: false)
  assert(name, errors.any? { |error| error.include?("duplicate removal selector") }, "missing duplicate selector diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects removal selector identity drift"
  entry = entry_for("codex", "stop")
  entry.fetch("removal_selector")["self_timeout_ms"] = 1
  errors = StrictModeHookEntryPlan.validate([entry], selected_output_contracts: [], enforce: false)
  assert(name, errors.any? { |error| error.include?("removal_selector.self_timeout_ms mismatch") }, "missing timeout selector diagnostic", errors.join("\n"))
  assert(name, errors.any? { |error| error.include?("removal_selector.entry_hash mismatch") }, "missing selector hash diagnostic", errors.join("\n"))
end

run_case do
  name = "validation rejects unsorted managed hook entries"
  entries = [entry_for("codex", "stop"), entry_for("codex", "pre-tool-use")]
  errors = StrictModeHookEntryPlan.validate(entries, selected_output_contracts: [], enforce: false)
  assert(name, errors.any? { |error| error.include?("managed hook entries must be sorted") }, "missing sorted managed entry diagnostic", errors.join("\n"))
end

run_case do
  name = "apply rejects malformed enforcing entries with controlled validation"
  malformed = [entry_for("codex", "stop")]
  malformed.first.delete("provider")
  begin
    StrictModeHookEntryPlan.apply(
      malformed,
      selected_output_contracts: [selected_output("codex", "stop", "codex.stop.block")],
      enforce: true
    )
    record_failure(name, "expected malformed entry rejection")
  rescue RuntimeError => e
    assert(name, e.message.include?("missing fields: provider"), "wrong malformed-entry diagnostic", e.message)
    assert(name, !e.message.include?("key not found"), "leaked KeyError instead of controlled validation", e.message)
  end
end

run_case do
  name = "validation rejects unused selected output contracts"
  entries = [entry_for("codex", "pre-tool-use")]
  selected = [
    selected_output("codex", "pre-tool-use", "codex.pre.block"),
    selected_output("codex", "stop", "codex.stop.block")
  ]
  planned = StrictModeHookEntryPlan.apply(entries, selected_output_contracts: [selected.first], enforce: true)
  errors = StrictModeHookEntryPlan.validate(planned, selected_output_contracts: selected, enforce: true)
  assert(name, errors.any? { |error| error.include?("selected output contract for codex stop has no matching blocking hook entry") }, "missing unused contract diagnostic", errors.join("\n"))
end

if $failures.empty?
  puts "hook entry plan tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
