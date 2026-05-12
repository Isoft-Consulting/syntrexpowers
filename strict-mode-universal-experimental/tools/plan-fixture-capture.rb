#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "shellwords"
require_relative "fixture_readiness_lib"

PLAN_SCHEMA_VERSION = 1

def usage_error(message)
  warn "fixture capture plan usage error: #{message}"
  exit 2
end

def safe_component(value)
  StrictModeFixtures.safe_component(value)
rescue ArgumentError
  "contract"
end

def event_argument(check)
  accepted_events = check.fetch("accepted_events")
  return accepted_events.first if accepted_events.length == 1

  "<#{accepted_events.join("-or-")}>"
end

def contract_id_placeholder(provider, event, contract_kind)
  safe_event = event.start_with?("<") ? event.delete_prefix("<").delete_suffix(">").split("-or-").first : event
  suffix = case contract_kind
           when "payload-schema"
             "payload"
           when "command-execution"
             "command"
           when "event-order"
             "order"
           when "decision-output"
             "block"
           else
             contract_kind
           end
  "<#{provider}.#{safe_component(safe_event)}.#{suffix}>"
end

def provider_version_args(provider_version)
  ["--provider-version", provider_version]
end

def provider_build_hash_args(provider_build_hash)
  provider_build_hash.empty? ? [] : ["--provider-build-hash", provider_build_hash]
end

def command_tokens(tokens)
  tokens.map do |token|
    token.to_s.start_with?("<") && token.to_s.end_with?(">") ? token.to_s : Shellwords.escape(token.to_s)
  end.join(" ")
end

def command_example(check, importer, required_inputs, provider_version, provider_build_hash)
  provider = check.fetch("provider")
  event = event_argument(check)
  contract_kind = check.fetch("contract_kind")
  base = ["ruby", importer, "--provider", provider, "--event", event]
  base.concat(provider_version_args(provider_version))
  base.concat(provider_build_hash_args(provider_build_hash))
  case contract_kind
  when "payload-schema"
    command_tokens(base + ["--source", "<captured-payload.json>", "--cwd", "<provider-cwd>", "--project-dir", "<project-root>"])
  when "decision-output"
    command_tokens(
      base + [
        "--contract-kind", contract_kind,
        "--contract-id", contract_id_placeholder(provider, event, contract_kind),
        "--metadata", "<provider-output.json>",
        "--stdout", "<stdout>",
        "--stderr", "<stderr>",
        "--exit-code", "<exit-code>"
      ]
    )
  else
    command_tokens(
      base + [
        "--contract-kind", contract_kind,
        "--contract-id", contract_id_placeholder(provider, event, contract_kind),
        "--source", required_inputs.first.fetch("placeholder")
      ]
    )
  end
end

def importer_for(contract_kind)
  case contract_kind
  when "payload-schema"
    "tools/import-discovery-fixture.rb"
  else
    "tools/import-contract-fixture.rb"
  end
end

def required_inputs_for(contract_kind)
  case contract_kind
  when "payload-schema"
    [
      { "name" => "source_payload", "placeholder" => "<captured-payload.json>", "description" => "raw duplicate-key-safe provider JSON payload" },
      { "name" => "cwd", "placeholder" => "<provider-cwd>", "description" => "cwd reported by the provider when the payload was captured" },
      { "name" => "project_dir", "placeholder" => "<project-root>", "description" => "project root used for normalized-event path containment" }
    ]
  when "decision-output"
    [
      { "name" => "provider_output_metadata", "placeholder" => "<provider-output.json>", "description" => "decision.provider-output.v1 metadata for the provider action" },
      { "name" => "stdout", "placeholder" => "<stdout>", "description" => "captured provider stdout bytes" },
      { "name" => "stderr", "placeholder" => "<stderr>", "description" => "captured provider stderr bytes" },
      { "name" => "exit_code", "placeholder" => "<exit-code>", "description" => "captured provider exit code file" }
    ]
  else
    [
      { "name" => "proof_source", "placeholder" => "<proof-file>", "description" => "#{contract_kind} proof artifact" }
    ]
  end
end

def capture_step(check, provider_version, provider_build_hash)
  contract_kind = check.fetch("contract_kind")
  importer = importer_for(contract_kind)
  required_inputs = required_inputs_for(contract_kind)
  {
    "provider" => check.fetch("provider"),
    "event" => check.fetch("event"),
    "accepted_events" => check.fetch("accepted_events"),
    "contract_kind" => contract_kind,
    "required" => check.fetch("required"),
    "message" => check.fetch("message"),
    "importer" => importer,
    "required_inputs" => required_inputs,
    "example_command" => command_example(check, importer, required_inputs, provider_version, provider_build_hash)
  }
end

def missing_steps(checks, provider_version, provider_build_hash)
  checks.reject { |check| check.fetch("ready") }.map { |check| capture_step(check, provider_version, provider_build_hash) }
end

def fixture_capture_plan(report)
  providers = report.fetch("providers").map do |provider_report|
    provider_version = provider_report.fetch("installed_version")
    provider_build_hash = provider_report.fetch("installed_build_hash")
    missing_required = missing_steps(provider_report.fetch("required_checks"), provider_version, provider_build_hash)
    missing_optional = missing_steps(provider_report.fetch("optional_checks"), provider_version, provider_build_hash)
    {
      "provider" => provider_report.fetch("provider"),
      "installed_version" => provider_version,
      "installed_build_hash" => provider_build_hash,
      "manifest_valid" => provider_report.fetch("manifest_valid"),
      "manifest_errors" => provider_report.fetch("manifest_errors"),
      "enforceable_record_count" => provider_report.fetch("enforceable_record_count"),
      "ready" => provider_report.fetch("ready"),
      "missing_required" => missing_required,
      "missing_optional" => missing_optional,
      "selected_output_contracts" => provider_report.fetch("selected_output_contracts")
    }
  end
  {
    "schema_version" => PLAN_SCHEMA_VERSION,
    "plan_kind" => "fixture-capture",
    "ready" => report.fetch("ready"),
    "providers" => providers,
    "missing_required_count" => providers.sum { |provider| provider.fetch("missing_required").length },
    "missing_optional_count" => providers.sum { |provider| provider.fetch("missing_optional").length }
  }
end

def print_text_plan(plan)
  puts "fixture capture plan: #{plan.fetch("ready") ? "ready" : "not-ready"}"
  plan.fetch("providers").each do |provider|
    puts "#{provider.fetch("provider")}: #{provider.fetch("ready") ? "ready" : "not-ready"} " \
         "(required missing: #{provider.fetch("missing_required").length}, optional missing: #{provider.fetch("missing_optional").length})"
    if provider.fetch("manifest_errors").any?
      provider.fetch("manifest_errors").each { |error| puts "  manifest: #{error}" }
      next
    end
    provider.fetch("missing_required").each do |step|
      puts "  required #{step.fetch("event")} #{step.fetch("contract_kind")} -> #{step.fetch("importer")}"
      puts "    #{step.fetch("example_command")}"
    end
    provider.fetch("missing_optional").each do |step|
      puts "  optional #{step.fetch("event")} #{step.fetch("contract_kind")} -> #{step.fetch("importer")}"
      puts "    #{step.fetch("example_command")}"
    end
  end
end

options = {
  root: StrictModeFixtures.project_root,
  provider: "all",
  format: "text",
  provider_versions: {},
  provider_build_hashes: {}
}

begin
  OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = Pathname.new(value) }
    opts.on("--provider PROVIDER") { |value| options[:provider] = value }
    opts.on("--format FORMAT") { |value| options[:format] = value }
    opts.on("--provider-version PROVIDER=VERSION") do |value|
      provider, version = StrictModeFixtureReadiness.parse_provider_version_assignment(value)
      options[:provider_versions][provider] = version
    end
    opts.on("--provider-build-hash PROVIDER=SHA256") do |value|
      provider, build_hash = StrictModeFixtureReadiness.parse_provider_build_hash_assignment(value)
      options[:provider_build_hashes][provider] = build_hash
    end
  end.parse!(ARGV)
rescue OptionParser::ParseError, ArgumentError => e
  usage_error(e.message)
end
usage_error("unexpected arguments: #{ARGV.join(" ")}") unless ARGV.empty?
usage_error("--format must be text or json") unless %w[text json].include?(options[:format])

begin
  providers = StrictModeFixtures.provider_list(options[:provider])
  StrictModeFixtureReadiness.validate_provider_versions!(options[:provider_versions], providers)
  StrictModeFixtureReadiness.validate_provider_build_hashes!(options[:provider_build_hashes], providers)
rescue ArgumentError => e
  usage_error(e.message)
end

begin
  report = StrictModeFixtureReadiness.enforcing_report(options[:root], providers, options[:provider_versions], options[:provider_build_hashes])
  plan = fixture_capture_plan(report)
rescue RuntimeError, ArgumentError => e
  warn "fixture capture plan failed: #{e.message}"
  exit 1
end

if options[:format] == "json"
  puts JSON.pretty_generate(plan)
else
  print_text_plan(plan)
end
