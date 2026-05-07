#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "shellwords"
require_relative "metadata_lib"

module StrictModeHookEntryPlan
  extend self

  ENTRY_FIELDS = %w[
    provider
    provider_version
    config_path
    hook_event
    logical_event
    matcher
    command
    provider_env
    self_timeout_ms
    provider_timeout_ms
    provider_timeout_field
    output_contract_id
    enforcing
    removal_selector
  ].freeze

  REMOVAL_SELECTOR_FIELDS = %w[
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
  ].freeze

  SELECTED_OUTPUT_FIELDS = %w[
    provider
    provider_version
    provider_build_hash
    platform
    event
    logical_event
    contract_kind
    contract_id
    provider_action
    decision_contract_hash
    fixture_record_hash
    fixture_manifest_hash
  ].freeze

  BLOCKING_EVENTS = %w[pre-tool-use stop permission-request].freeze
  PROVIDERS = %w[claude codex].freeze
  PROVIDER_ACTIONS = %w[block deny].freeze
  PROVIDER_TIMEOUT_FIELDS = ["", "timeout"].freeze
  LOGICAL_EVENT_TO_HOOK_EVENT = {
    "session-start" => "SessionStart",
    "user-prompt-submit" => "UserPromptSubmit",
    "pre-tool-use" => "PreToolUse",
    "post-tool-use" => "PostToolUse",
    "stop" => "Stop",
    "permission-request" => "PermissionRequest"
  }.freeze
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze

  def apply(entries, selected_output_contracts:, enforce:, install_root: nil)
    planned = deep_copy(entries)
    selected = deep_copy(selected_output_contracts || [])
    normalize_removal_selectors(planned)
    preflight_errors = validate_entry_shapes(planned, install_root)
    raise preflight_errors.join("; ") unless preflight_errors.empty?

    if enforce
      output_map = selected_output_map(selected)
      planned.each_with_index do |entry, index|
        ensure_entry_object!(entry, index)
        if blocking_entry?(entry)
          contract = output_map[[entry.fetch("provider"), entry.fetch("logical_event")]]
          unless contract
            raise "hook entry #{index}: missing selected output contract for #{entry.fetch("provider", "?")} #{entry.fetch("logical_event", "?")}"
          end
          entry["enforcing"] = true
          entry["output_contract_id"] = contract.fetch("contract_id")
        else
          entry["enforcing"] = false
          entry["output_contract_id"] = ""
        end
        entry["removal_selector"] = removal_selector_for(entry)
      end
    else
      planned.each_with_index do |entry, index|
        ensure_entry_object!(entry, index)
        entry["enforcing"] = false
        entry["output_contract_id"] = ""
        entry["removal_selector"] = removal_selector_for(entry)
      end
    end

    planned = sort_entries(planned)
    errors = validate(planned, selected_output_contracts: selected, enforce: enforce, install_root: install_root)
    raise errors.join("; ") unless errors.empty?

    planned
  end

  def validate(entries, selected_output_contracts:, enforce:, install_root: nil)
    return ["managed hook entries must be an array"] unless entries.is_a?(Array)

    errors = []
    output_map = {}
    if enforce
      output_errors = selected_output_contract_errors(selected_output_contracts || [])
      errors.concat(output_errors)
      output_map = build_selected_output_map(selected_output_contracts || []) if output_errors.empty?
    end

    selector_keys = {}
    bound_output_keys = {}
    sortable_entries = []
    entries.each_with_index do |entry, index|
      unless entry.is_a?(Hash)
        errors << "hook entry #{index}: must be an object"
        next
      end

      errors.concat(entry_shape_errors(entry, index, install_root))
      next unless exact_entry_shape?(entry)

      sortable_entries << entry
      selector_key = removal_selector_key(entry)
      if selector_keys.key?(selector_key)
        errors << "hook entry #{index}: duplicate removal selector also used by hook entry #{selector_keys.fetch(selector_key)}"
      else
        selector_keys[selector_key] = index
      end

      if enforce && BLOCKING_EVENTS.include?(entry.fetch("logical_event"))
        contract = output_map[[entry.fetch("provider"), entry.fetch("logical_event")]]
        if contract.nil?
          errors << "hook entry #{index}: missing selected output contract for #{entry.fetch("provider")} #{entry.fetch("logical_event")}"
        else
          expected_id = contract.fetch("contract_id")
          errors << "hook entry #{index}: enforcing must be true for #{entry.fetch("logical_event")}" unless entry.fetch("enforcing") == true
          errors << "hook entry #{index}: output_contract_id must be #{expected_id}" unless entry.fetch("output_contract_id") == expected_id
          errors << "hook entry #{index}: output_contract_id must be non-empty" if entry.fetch("output_contract_id").empty?
          bound_output_keys[[entry.fetch("provider"), entry.fetch("logical_event")]] = index
        end
      else
        errors << "hook entry #{index}: enforcing must be false in discovery/non-blocking plan" unless entry.fetch("enforcing") == false
        errors << "hook entry #{index}: output_contract_id must be empty in discovery/non-blocking plan" unless entry.fetch("output_contract_id") == ""
      end
    end

    if enforce && errors.empty?
      output_map.each_key do |key|
        next if bound_output_keys.key?(key)

        errors << "selected output contract for #{key.join(" ")} has no matching blocking hook entry"
      end
    end
    if sortable_entries.size == entries.size && entries != entries.sort_by { |entry| entry_sort_key(entry) }
      errors << "managed hook entries must be sorted by provider/config_path/hook identity"
    end

    errors
  end

  def selected_output_map(records)
    errors = selected_output_contract_errors(records)
    raise errors.join("; ") unless errors.empty?

    build_selected_output_map(records)
  end

  def selected_output_contract_errors(records)
    return ["selected_output_contracts must be an array"] unless records.is_a?(Array)

    errors = []
    keys = {}
    records.each_with_index do |record, index|
      unless record.is_a?(Hash)
        errors << "selected output contract #{index}: must be an object"
        next
      end

      missing = SELECTED_OUTPUT_FIELDS - record.keys
      extra = record.keys - SELECTED_OUTPUT_FIELDS
      errors << "selected output contract #{index}: missing fields: #{missing.join(", ")}" unless missing.empty?
      errors << "selected output contract #{index}: extra fields: #{extra.join(", ")}" unless extra.empty?
      next unless missing.empty? && extra.empty?

      provider = record.fetch("provider")
      event = record.fetch("event")
      logical_event = record.fetch("logical_event")
      contract_id = record.fetch("contract_id")
      key = [provider, logical_event]

      %w[
        provider
        provider_version
        provider_build_hash
        platform
        event
        logical_event
        contract_kind
        contract_id
        provider_action
        decision_contract_hash
        fixture_record_hash
        fixture_manifest_hash
      ].each do |field|
        errors << "selected output contract #{index}: #{field} must be a string" unless record.fetch(field).is_a?(String)
      end
      errors << "selected output contract #{index}: unsupported provider #{provider.inspect}" unless PROVIDERS.include?(provider)
      errors << "selected output contract #{index}: provider_version must be non-empty" if record.fetch("provider_version").is_a?(String) && record.fetch("provider_version").empty?
      errors << "selected output contract #{index}: platform must be non-empty" if record.fetch("platform").is_a?(String) && record.fetch("platform").empty?
      errors << "selected output contract #{index}: event must match logical_event" unless event == logical_event
      errors << "selected output contract #{index}: logical_event must be blocking" unless BLOCKING_EVENTS.include?(logical_event)
      errors << "selected output contract #{index}: contract_kind must be decision-output" unless record.fetch("contract_kind") == "decision-output"
      errors << "selected output contract #{index}: provider_action must be block or deny" unless PROVIDER_ACTIONS.include?(record.fetch("provider_action"))
      errors << "selected output contract #{index}: contract_id must be non-empty" unless contract_id.is_a?(String) && !contract_id.empty?
      %w[decision_contract_hash fixture_record_hash fixture_manifest_hash].each do |field|
        errors << "selected output contract #{index}: #{field} must be lowercase SHA-256" unless record.fetch(field).is_a?(String) && record.fetch(field).match?(SHA256_PATTERN)
      end

      if keys.key?(key)
        errors << "selected output contract #{index}: duplicate provider/logical_event tuple also used by selected output contract #{keys.fetch(key)}"
      else
        keys[key] = index
      end
    end
    errors
  end

  def blocking_entry?(entry)
    entry.is_a?(Hash) && BLOCKING_EVENTS.include?(entry["logical_event"])
  end

  def provider_env_hash(provider_env)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(provider_env))
  end

  def hook_entry_hash(entry)
    clone = deep_copy(entry)
    selector = clone["removal_selector"]
    selector["entry_hash"] = "" if selector.is_a?(Hash)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(clone))
  end

  def removal_selector_for(entry)
    selector = {
      "provider" => entry.fetch("provider"),
      "config_path" => entry.fetch("config_path"),
      "hook_event" => entry.fetch("hook_event"),
      "matcher" => entry.fetch("matcher"),
      "command" => entry.fetch("command"),
      "provider_env_hash" => provider_env_hash(entry.fetch("provider_env")),
      "self_timeout_ms" => entry.fetch("self_timeout_ms"),
      "provider_timeout_ms" => entry.fetch("provider_timeout_ms"),
      "provider_timeout_field" => entry.fetch("provider_timeout_field"),
      "output_contract_id" => entry.fetch("output_contract_id"),
      "entry_hash" => ""
    }
    clone = deep_copy(entry)
    clone["removal_selector"] = selector
    selector["entry_hash"] = hook_entry_hash(clone)
    selector
  end

  def sort_entries(entries)
    deep_copy(entries).sort_by { |entry| entry_sort_key(entry) }
  end

  private

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def ensure_entry_object!(entry, index)
    raise "hook entry #{index}: must be an object" unless entry.is_a?(Hash)
  end

  def validate_entry_shapes(entries, install_root)
    return ["managed hook entries must be an array"] unless entries.is_a?(Array)

    entries.each_with_index.each_with_object([]) do |(entry, index), errors|
      if entry.is_a?(Hash)
        errors.concat(entry_shape_errors(entry, index, install_root))
      else
        errors << "hook entry #{index}: must be an object"
      end
    end
  end

  def normalize_removal_selectors(entries)
    return unless entries.is_a?(Array)

    entries.each do |entry|
      next unless entry.is_a?(Hash) && can_build_removal_selector?(entry)

      entry["removal_selector"] = removal_selector_for(entry)
    rescue KeyError, ArgumentError
      next
    end
  end

  def can_build_removal_selector?(entry)
    (ENTRY_FIELDS - ["removal_selector"]).all? { |field| entry.key?(field) }
  end

  def exact_entry_shape?(entry)
    (ENTRY_FIELDS - entry.keys).empty? && (entry.keys - ENTRY_FIELDS).empty? &&
      entry["removal_selector"].is_a?(Hash) &&
      (REMOVAL_SELECTOR_FIELDS - entry["removal_selector"].keys).empty? &&
      (entry["removal_selector"].keys - REMOVAL_SELECTOR_FIELDS).empty?
  end

  def entry_shape_errors(entry, index, install_root)
    errors = []
    missing = ENTRY_FIELDS - entry.keys
    extra = entry.keys - ENTRY_FIELDS
    errors << "hook entry #{index}: missing fields: #{missing.join(", ")}" unless missing.empty?
    errors << "hook entry #{index}: extra fields: #{extra.join(", ")}" unless extra.empty?
    return errors unless missing.empty? && extra.empty?

    errors << "hook entry #{index}: unsupported provider #{entry.fetch("provider").inspect}" unless PROVIDERS.include?(entry.fetch("provider"))
    %w[provider_version config_path hook_event logical_event matcher command provider_timeout_field output_contract_id].each do |field|
      errors << "hook entry #{index}: #{field} must be a string" unless entry.fetch(field).is_a?(String)
    end
    errors << "hook entry #{index}: provider_version must be non-empty" if entry.fetch("provider_version").is_a?(String) && entry.fetch("provider_version").empty?
    errors << "hook entry #{index}: config_path must be non-empty" if entry.fetch("config_path").is_a?(String) && entry.fetch("config_path").empty?
    if entry.fetch("provider_env").is_a?(Hash)
      entry.fetch("provider_env").each do |key, value|
        errors << "hook entry #{index}: provider_env keys and values must be strings" unless key.is_a?(String) && value.is_a?(String)
      end
    else
      errors << "hook entry #{index}: provider_env must be an object"
    end
    %w[self_timeout_ms provider_timeout_ms].each do |field|
      value = entry.fetch(field)
      errors << "hook entry #{index}: #{field} must be a non-negative integer" unless value.is_a?(Integer) && value >= 0
    end
    if entry.fetch("self_timeout_ms").is_a?(Integer) && entry.fetch("provider_timeout_ms").is_a?(Integer)
      provider_timeout_field = entry.fetch("provider_timeout_field")
      if entry.fetch("provider_timeout_ms").zero?
        errors << "hook entry #{index}: provider_timeout_field must be empty when provider_timeout_ms is 0" unless provider_timeout_field == ""
      else
        errors << "hook entry #{index}: provider_timeout_field must be non-empty when provider_timeout_ms is nonzero" if provider_timeout_field.is_a?(String) && provider_timeout_field.empty?
        if entry.fetch("provider_timeout_ms") < entry.fetch("self_timeout_ms") + 1_000
          errors << "hook entry #{index}: provider_timeout_ms must be at least self_timeout_ms + 1000"
        end
      end
    end
    errors << "hook entry #{index}: enforcing must be boolean" unless [true, false].include?(entry.fetch("enforcing"))
    errors.concat(command_errors(entry, index, install_root))
    if entry.fetch("logical_event").is_a?(String)
      expected_hook_event = LOGICAL_EVENT_TO_HOOK_EVENT[entry.fetch("logical_event")]
      errors << "hook entry #{index}: unsupported logical_event #{entry.fetch("logical_event").inspect}" unless expected_hook_event
      errors << "hook entry #{index}: hook_event must be #{expected_hook_event}" if expected_hook_event && entry.fetch("hook_event") != expected_hook_event
    end
    errors << "hook entry #{index}: provider_timeout_field must be empty or timeout" unless PROVIDER_TIMEOUT_FIELDS.include?(entry.fetch("provider_timeout_field"))
    errors.concat(removal_selector_errors(entry, index))
    errors
  end

  def removal_selector_errors(entry, index)
    selector = entry.fetch("removal_selector")
    unless selector.is_a?(Hash)
      return ["hook entry #{index}: removal_selector must be an object"]
    end

    errors = []
    missing = REMOVAL_SELECTOR_FIELDS - selector.keys
    extra = selector.keys - REMOVAL_SELECTOR_FIELDS
    errors << "hook entry #{index}: removal_selector missing fields: #{missing.join(", ")}" unless missing.empty?
    errors << "hook entry #{index}: removal_selector extra fields: #{extra.join(", ")}" unless extra.empty?
    return errors unless missing.empty? && extra.empty?

    %w[provider config_path hook_event matcher command provider_env_hash provider_timeout_field output_contract_id entry_hash].each do |field|
      errors << "hook entry #{index}: removal_selector.#{field} must be a string" unless selector.fetch(field).is_a?(String)
    end
    %w[self_timeout_ms provider_timeout_ms].each do |field|
      errors << "hook entry #{index}: removal_selector.#{field} must be a non-negative integer" unless selector.fetch(field).is_a?(Integer) && selector.fetch(field) >= 0
    end
    %w[provider config_path hook_event matcher command provider_timeout_field output_contract_id].each do |field|
      errors << "hook entry #{index}: removal_selector.#{field} mismatch" unless selector.fetch(field) == entry.fetch(field)
    end
    %w[self_timeout_ms provider_timeout_ms].each do |field|
      errors << "hook entry #{index}: removal_selector.#{field} mismatch" unless selector.fetch(field) == entry.fetch(field)
    end
    if selector.fetch("provider_env_hash").is_a?(String) && entry.fetch("provider_env").is_a?(Hash)
      errors << "hook entry #{index}: removal_selector.provider_env_hash must be lowercase SHA-256" unless selector.fetch("provider_env_hash").match?(SHA256_PATTERN)
      errors << "hook entry #{index}: removal_selector.provider_env_hash mismatch" unless selector.fetch("provider_env_hash") == provider_env_hash(entry.fetch("provider_env"))
    end
    if selector.fetch("entry_hash").is_a?(String)
      errors << "hook entry #{index}: removal_selector.entry_hash must be lowercase SHA-256" unless selector.fetch("entry_hash").match?(SHA256_PATTERN)
      errors << "hook entry #{index}: removal_selector.entry_hash mismatch" unless selector.fetch("entry_hash") == hook_entry_hash(entry)
    end
    errors << "hook entry #{index}: removal_selector.config_path must be non-empty" if selector.fetch("config_path").is_a?(String) && selector.fetch("config_path").empty?
    errors
  rescue ArgumentError => e
    ["hook entry #{index}: removal_selector hash verification failed: #{e.message}"]
  end

  def command_errors(entry, index, install_root)
    return [] unless entry.fetch("command").is_a?(String)

    command = entry.fetch("command")
    errors = []
    unless command.match?(/\ASTRICT_HOOK_TIMEOUT_MS=\d+\s+"(?:[^"\\]|\\.)+"\s+--provider\s+\S+\s+\S+\z/)
      errors << "hook entry #{index}: command must be STRICT_HOOK_TIMEOUT_MS=<ms> \"<install-root>/active/bin/strict-hook\" --provider <provider> <logical_event>"
      return errors
    end

    parts = Shellwords.split(command)
    unless parts.size == 5
      errors << "hook entry #{index}: command must have exactly timeout assignment, hook path, --provider, provider, logical_event"
      return errors
    end

    timeout_match = parts.fetch(0).match(/\ASTRICT_HOOK_TIMEOUT_MS=(\d+)\z/)
    unless timeout_match && entry.fetch("self_timeout_ms").is_a?(Integer) && timeout_match[1].to_i == entry.fetch("self_timeout_ms")
      errors << "hook entry #{index}: command STRICT_HOOK_TIMEOUT_MS must match self_timeout_ms"
    end
    hook_path = Pathname.new(parts.fetch(1))
    errors << "hook entry #{index}: command hook path must be absolute" unless hook_path.absolute?
    errors << "hook entry #{index}: command hook path must be canonical lexical path" unless hook_path.cleanpath.to_s == hook_path.to_s
    errors << "hook entry #{index}: command hook path must end with /active/bin/strict-hook" unless hook_path.to_s.end_with?("/active/bin/strict-hook")
    errors << "hook entry #{index}: command hook path must not target a release realpath" if hook_path.to_s.include?("/releases/")
    if install_root
      expected_hook_path = Pathname.new(install_root).join("active/bin/strict-hook").to_s
      errors << "hook entry #{index}: command hook path must match install_root active strict-hook" unless hook_path.to_s == expected_hook_path
    end
    errors << "hook entry #{index}: command argv must include --provider" unless parts.fetch(2) == "--provider"
    errors << "hook entry #{index}: command provider argv mismatch" unless parts.fetch(3) == entry.fetch("provider")
    errors << "hook entry #{index}: command logical_event argv mismatch" unless parts.fetch(4) == entry.fetch("logical_event")
    errors
  rescue ArgumentError => e
    ["hook entry #{index}: command shell parsing failed: #{e.message}"]
  end

  def removal_selector_key(entry)
    selector = entry.fetch("removal_selector")
    REMOVAL_SELECTOR_FIELDS.map { |field| selector.fetch(field) }
  end

  def entry_sort_key(entry)
    selector = entry.fetch("removal_selector")
    [
      entry.fetch("provider"),
      entry.fetch("config_path"),
      entry.fetch("hook_event"),
      entry.fetch("matcher"),
      entry.fetch("command"),
      selector.fetch("provider_env_hash"),
      entry.fetch("self_timeout_ms"),
      entry.fetch("provider_timeout_ms"),
      entry.fetch("provider_timeout_field"),
      entry.fetch("output_contract_id")
    ]
  end

  def build_selected_output_map(records)
    records.each_with_object({}) do |record, map|
      map[[record.fetch("provider"), record.fetch("logical_event")]] = record
    end
  end
end
