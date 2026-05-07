#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require_relative "decision_contract_lib"
require_relative "fixture_manifest_lib"

module StrictModeFixtureReadiness
  extend self

  GENERATED_HOOK_EVENTS = %w[
    session-start
    user-prompt-submit
    pre-tool-use
    post-tool-use
    stop
  ].freeze
  REQUIRED_BLOCKING_EVENTS = %w[pre-tool-use stop].freeze
  OPTIONAL_BLOCKING_EVENTS = %w[permission-request].freeze
  BLOCKING_EVENTS = (REQUIRED_BLOCKING_EVENTS + OPTIONAL_BLOCKING_EVENTS).freeze
  EARLY_BASELINE_EVENTS = %w[session-start user-prompt-submit].freeze
  REPORT_SCHEMA_VERSION = 1

  def fixture_manifest_records(root, providers)
    root = Pathname.new(root)
    providers.flat_map do |provider|
      manifest_errors = StrictModeFixtures.validate_provider_manifest(root, provider)
      raise manifest_errors.join("\n") unless manifest_errors.empty?

      manifest = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, provider))
      manifest.fetch("records").map do |record|
        {
          "provider" => record.fetch("provider"),
          "provider_version" => record.fetch("provider_version"),
          "provider_build_hash" => record.fetch("provider_build_hash"),
          "platform" => record.fetch("platform"),
          "event" => record.fetch("event"),
          "contract_kind" => record.fetch("contract_kind"),
          "contract_id" => record.fetch("contract_id"),
          "fixture_record_hash" => record.fetch("fixture_record_hash"),
          "fixture_manifest_hash" => manifest.fetch("manifest_hash")
        }
      end
    end.sort_by { |record| fixture_record_sort_key(record) }.tap do |records|
      tuples = records.map { |record| fixture_record_sort_key(record) }
      raise "fixture_manifest_records tuples must be unique" unless tuples == tuples.uniq
    end
  end

  def selected_output_contracts(root, providers, provider_versions = {})
    root = Pathname.new(root)
    records_by_provider = load_manifest_records(root, providers)
    providers.flat_map do |provider|
      installed_version = provider_versions.fetch(provider, "unknown")
      enforceable = records_by_provider.fetch(provider, []).select { |record| enforceable_record?(record, installed_version) }
      selected_events = REQUIRED_BLOCKING_EVENTS + OPTIONAL_BLOCKING_EVENTS.select { |event| optional_blocking_ready?(enforceable, event) }
      selected_events.map do |event|
        selected_blocking_decision_output(root, enforceable, provider, event)
      end.compact
    end.sort_by { |record| selected_output_sort_key(record) }.tap do |records|
      tuples = records.map { |record| selected_output_sort_key(record) }
      raise "selected_output_contract tuples must be unique" unless tuples == tuples.uniq
    end
  end

  def load_manifest_records(root, providers)
    root = Pathname.new(root)
    providers.each_with_object({}) do |provider, records_by_provider|
      manifest_errors = StrictModeFixtures.validate_provider_manifest(root, provider)
      raise manifest_errors.join("\n") unless manifest_errors.empty?

      records_by_provider[provider] = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, provider)).fetch("records")
    end
  end

  def enforcing_errors(root, providers, provider_versions = {})
    root = Pathname.new(root)
    records_by_provider = {}
    errors = []
    providers.each do |provider|
      manifest_errors = StrictModeFixtures.validate_provider_manifest(root, provider)
      unless manifest_errors.empty?
        errors.concat(manifest_errors.map { |message| "fixture manifest invalid for #{provider}: #{message}" })
        next
      end

      records_by_provider[provider] = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, provider)).fetch("records")
    rescue RuntimeError => e
      errors << "fixture manifest invalid for #{provider}: #{e.message}"
    end
    return errors unless errors.empty?

    providers.each do |provider|
      records = records_by_provider.fetch(provider, [])
      installed_version = provider_versions.fetch(provider, "unknown")
      enforceable = records.select { |record| enforceable_record?(record, installed_version) }
      EARLY_BASELINE_EVENTS.any? { |event| record_exists?(enforceable, event, "event-order") } ||
        errors << "missing #{provider} event-order fixture for early baseline before tool execution"
      GENERATED_HOOK_EVENTS.each do |event|
        record_exists?(enforceable, event, "payload-schema") ||
          errors << "missing #{provider} #{event} payload-schema fixture"
        record_exists?(enforceable, event, "command-execution") ||
          errors << "missing #{provider} #{event} command-execution fixture"
      end
      record_exists?(enforceable, "pre-tool-use", "matcher") ||
        errors << "missing #{provider} pre-tool-use matcher fixture"
      REQUIRED_BLOCKING_EVENTS.each do |event|
        selected_blocking_decision_output(root, enforceable, provider, event) ||
          errors << "missing #{provider} #{event} decision-output fixture with block/deny provider output"
      end
    end
    errors
  end

  def enforcing_report(root, providers, provider_versions = {})
    root = Pathname.new(root)
    provider_reports = providers.map do |provider|
      provider_report(root, provider, provider_versions.fetch(provider, "unknown"))
    end
    errors = provider_reports.flat_map { |report| report.fetch("errors") }
    {
      "schema_version" => REPORT_SCHEMA_VERSION,
      "report_kind" => "enforcing-readiness",
      "ready" => errors.empty?,
      "providers" => provider_reports,
      "errors" => errors
    }
  end

  def provider_report(root, provider, installed_version)
    manifest_errors = StrictModeFixtures.validate_provider_manifest(root, provider)
    unless manifest_errors.empty?
      errors = manifest_errors.map { |message| "fixture manifest invalid for #{provider}: #{message}" }
      return {
        "provider" => provider,
        "installed_version" => installed_version,
        "manifest_valid" => false,
        "manifest_errors" => manifest_errors,
        "enforceable_record_count" => 0,
        "required_checks" => [],
        "optional_checks" => [],
        "selected_output_contracts" => [],
        "ready" => false,
        "errors" => errors
      }
    end

    records = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, provider)).fetch("records")
    enforceable = records.select { |record| enforceable_record?(record, installed_version) }
    required_checks = required_checks_for(root, provider, enforceable)
    optional_checks = optional_checks_for(root, provider, enforceable)
    errors = required_checks.reject { |check| check.fetch("ready") }.map { |check| check.fetch("message") }
    selected = selected_output_contracts(root, [provider], provider => installed_version)
    {
      "provider" => provider,
      "installed_version" => installed_version,
      "manifest_valid" => true,
      "manifest_errors" => [],
      "enforceable_record_count" => enforceable.length,
      "required_checks" => required_checks,
      "optional_checks" => optional_checks,
      "selected_output_contracts" => selected,
      "ready" => errors.empty?,
      "errors" => errors
    }
  end

  def required_checks_for(root, provider, enforceable)
    checks = []
    early_records = matching_records(enforceable, EARLY_BASELINE_EVENTS, "event-order")
    checks << readiness_check(
      provider: provider,
      event: "early-baseline",
      accepted_events: EARLY_BASELINE_EVENTS,
      contract_kind: "event-order",
      records: early_records,
      message: "missing #{provider} event-order fixture for early baseline before tool execution"
    )
    GENERATED_HOOK_EVENTS.each do |event|
      checks << readiness_check(
        provider: provider,
        event: event,
        contract_kind: "payload-schema",
        records: matching_records(enforceable, [event], "payload-schema"),
        message: "missing #{provider} #{event} payload-schema fixture"
      )
      checks << readiness_check(
        provider: provider,
        event: event,
        contract_kind: "command-execution",
        records: matching_records(enforceable, [event], "command-execution"),
        message: "missing #{provider} #{event} command-execution fixture"
      )
    end
    checks << readiness_check(
      provider: provider,
      event: "pre-tool-use",
      contract_kind: "matcher",
      records: matching_records(enforceable, ["pre-tool-use"], "matcher"),
      message: "missing #{provider} pre-tool-use matcher fixture"
    )
    REQUIRED_BLOCKING_EVENTS.each do |event|
      selected = selected_blocking_decision_output(root, enforceable, provider, event)
      checks << readiness_check(
        provider: provider,
        event: event,
        contract_kind: "decision-output",
        records: selected ? [selected] : [],
        message: "missing #{provider} #{event} decision-output fixture with block/deny provider output"
      )
    end
    checks
  end

  def optional_checks_for(root, provider, enforceable)
    OPTIONAL_BLOCKING_EVENTS.flat_map do |event|
      selected = selected_blocking_decision_output(root, enforceable, provider, event)
      [
        readiness_check(
          provider: provider,
          event: event,
          contract_kind: "payload-schema",
          records: matching_records(enforceable, [event], "payload-schema"),
          required: false
        ),
        readiness_check(
          provider: provider,
          event: event,
          contract_kind: "command-execution",
          records: matching_records(enforceable, [event], "command-execution"),
          required: false
        ),
        readiness_check(
          provider: provider,
          event: event,
          contract_kind: "decision-output",
          records: selected ? [selected] : [],
          required: false
        )
      ]
    end
  end

  def matching_records(records, events, contract_kind)
    records.select { |record| events.include?(record["event"]) && record["contract_kind"] == contract_kind }
  end

  def readiness_check(provider:, event:, contract_kind:, records:, message: "", required: true, accepted_events: [event])
    {
      "provider" => provider,
      "event" => event,
      "accepted_events" => accepted_events,
      "contract_kind" => contract_kind,
      "required" => required,
      "ready" => !records.empty?,
      "contract_ids" => records.map { |record| record.fetch("contract_id") }.sort,
      "message" => records.empty? ? message : ""
    }
  end

  def enforceable_record?(record, installed_version)
    return false unless record.is_a?(Hash) && record["provider_version"].is_a?(String)

    mode = record.dig("compatibility_range", "mode")
    case mode
    when "unknown-only"
      installed_version == "unknown" && record["provider_version"] == "unknown"
    when "exact"
      installed_version != "unknown" && record["provider_version"] == installed_version
    when "range"
      false
    else
      false
    end
  end

  def record_exists?(records, event, contract_kind)
    records.any? do |record|
      record["event"] == event && record["contract_kind"] == contract_kind
    end
  end

  def optional_blocking_ready?(records, event)
    record_exists?(records, event, "payload-schema") &&
      record_exists?(records, event, "command-execution") &&
      records.any? { |record| record["event"] == event && record["contract_kind"] == "decision-output" }
  end

  def selected_blocking_decision_output(root, records, provider, event)
    manifest = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, provider))
    candidates = records.select { |record| record["provider"] == provider && record["event"] == event && record["contract_kind"] == "decision-output" }.
      each_with_object([]) do |record, selected|
        metadata = decision_output_metadata(root, record)
        next unless metadata
        next unless metadata["provider"] == provider &&
                    metadata["event"] == event &&
                    metadata["logical_event"] == event &&
                    %w[block deny].include?(metadata["provider_action"]) &&
                    metadata["blocks_or_denies"] == 1 &&
                    StrictModeDecisionContract.validate_provider_output(metadata).empty?

        selected << selected_output_contract_record(record, metadata, manifest.fetch("manifest_hash"))
      end
    candidates.sort_by { |record| [record.fetch("provider_action") == "block" ? 0 : 1, record.fetch("contract_id")] }.first
  end

  def decision_output_metadata(root, record)
    roles = StrictModeFixtures.decision_output_fixture_roles(record)
    return nil unless roles["metadata"].length == 1

    metadata_path = StrictModeFixtures.fixture_path_for(root, record["provider"], roles["metadata"].first)
    return nil unless StrictModeFixtures.safe_fixture_file?(metadata_path)

    StrictModeFixtures.load_json(metadata_path)
  rescue RuntimeError, SystemCallError, JSON::ParserError
    nil
  end

  def selected_output_contract_record(record, metadata, fixture_manifest_hash)
    {
      "provider" => record.fetch("provider"),
      "provider_version" => record.fetch("provider_version"),
      "provider_build_hash" => record.fetch("provider_build_hash"),
      "platform" => record.fetch("platform"),
      "event" => record.fetch("event"),
      "logical_event" => metadata.fetch("logical_event"),
      "contract_kind" => record.fetch("contract_kind"),
      "contract_id" => record.fetch("contract_id"),
      "provider_action" => metadata.fetch("provider_action"),
      "decision_contract_hash" => record.fetch("decision_contract_hash"),
      "fixture_record_hash" => record.fetch("fixture_record_hash"),
      "fixture_manifest_hash" => fixture_manifest_hash
    }
  end

  def fixture_record_sort_key(record)
    [
      record.fetch("provider"),
      record.fetch("platform"),
      record.fetch("event"),
      record.fetch("contract_kind"),
      record.fetch("contract_id")
    ]
  end

  def selected_output_sort_key(record)
    [
      record.fetch("provider"),
      record.fetch("platform"),
      record.fetch("event"),
      record.fetch("contract_kind"),
      record.fetch("contract_id")
    ]
  end
end
