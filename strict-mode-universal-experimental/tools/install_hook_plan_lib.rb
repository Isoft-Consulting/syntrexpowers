#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "hook_entry_plan_lib"

module StrictModeInstallHookPlan
  extend self

  def double_quote_shell(path)
    %("#{path.to_s.gsub(/["\\$`]/) { |char| "\\#{char}" }}")
  end

  def command_for(install_root, state_root, provider, logical_event, timeout_ms, output_contract_id: "")
    hook_path = install_root.join("active/bin/strict-hook")
    state_root_path = Pathname.new(state_root)
    assignments = [
      "STRICT_HOOK_TIMEOUT_MS=#{timeout_ms}",
      "STRICT_STATE_ROOT=#{double_quote_shell(state_root_path)}"
    ]
    unless output_contract_id.to_s.empty?
      assignments << "STRICT_ENFORCING_HOOK=1"
      assignments << "STRICT_OUTPUT_CONTRACT_ID=#{double_quote_shell(output_contract_id)}"
    end
    "#{assignments.join(" ")} #{double_quote_shell(hook_path)} --provider #{provider} #{logical_event}"
  end

  def hook_specs(provider, include_permission_request: false)
    timeout_field = provider == "claude" ? "timeout" : ""
    specs = [
      ["SessionStart", "session-start", "", 5_000, provider == "claude" ? 6_000 : 0, timeout_field],
      ["UserPromptSubmit", "user-prompt-submit", "", 3_000, provider == "claude" ? 4_000 : 0, timeout_field],
      ["PreToolUse", "pre-tool-use", ".*", 5_000, provider == "claude" ? 6_000 : 0, timeout_field],
      ["PostToolUse", "post-tool-use", ".*", 3_000, provider == "claude" ? 4_000 : 0, timeout_field],
      ["Stop", "stop", "", 60_000, provider == "claude" ? 61_000 : 0, timeout_field]
    ]
    if include_permission_request
      specs << ["PermissionRequest", "permission-request", ".*", 5_000, provider == "claude" ? 6_000 : 0, timeout_field]
    end
    specs
  end

  def normalize_selected_output_contracts(records)
    selected = Array(records)
    return selected if selected.empty?

    errors = StrictModeHookEntryPlan.selected_output_contract_errors(selected)
    raise errors.join("; ") unless errors.empty?

    selected
  end

  def managed_entries(provider, config_path, install_root, state_root: nil, selected_output_contracts: [], enforce: false)
    selected = normalize_selected_output_contracts(selected_output_contracts)
    state_root_path = Pathname.new(state_root || install_root.join("state"))
    include_permission_request = selected.any? do |record|
      record["provider"] == provider && record["logical_event"] == "permission-request"
    end
    entries = hook_specs(provider, include_permission_request: include_permission_request).map do |event, logical_event, matcher, self_timeout_ms, provider_timeout_ms, provider_timeout_field|
      command = command_for(install_root, state_root_path, provider, logical_event, self_timeout_ms)
      {
        "provider" => provider,
        "provider_version" => "unknown",
        "config_path" => config_path.to_s,
        "hook_event" => event,
        "logical_event" => logical_event,
        "matcher" => matcher,
        "command" => command,
        "provider_env" => {},
        "self_timeout_ms" => self_timeout_ms,
        "provider_timeout_ms" => provider_timeout_ms,
        "provider_timeout_field" => provider_timeout_field,
        "output_contract_id" => "",
        "enforcing" => false,
        "removal_selector" => {}
      }
    end
    planned = StrictModeHookEntryPlan.apply(entries, selected_output_contracts: selected, enforce: enforce, install_root: install_root, state_root: state_root_path)
    planned.each do |entry|
      output_contract_id = entry.fetch("enforcing") ? entry.fetch("output_contract_id") : ""
      entry["command"] = command_for(
        install_root,
        state_root_path,
        provider,
        entry.fetch("logical_event"),
        entry.fetch("self_timeout_ms"),
        output_contract_id: output_contract_id
      )
    end
    StrictModeHookEntryPlan.apply(planned, selected_output_contracts: selected, enforce: enforce, install_root: install_root, state_root: state_root_path)
  end

  def hook_config_entry(entry)
    hook = { "type" => "command", "command" => entry.fetch("command") }
    hook["timeout"] = entry.fetch("provider_timeout_ms") if entry.fetch("provider_timeout_field") == "timeout"
    config_entry = { "hooks" => [hook] }
    config_entry["matcher"] = entry.fetch("matcher") unless entry.fetch("matcher").empty?
    config_entry
  end
end
