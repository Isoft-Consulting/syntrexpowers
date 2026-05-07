#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/decision_contract_lib"
require_relative "../tools/fixture_readiness_lib"

ROOT = StrictModeMetadata.project_root
CHECKER = ROOT.join("tools/check-fixture-readiness.rb")
IMPORTER = ROOT.join("tools/import-discovery-fixture.rb")

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert_no_stacktrace(name, output)
  return unless output.match?(/(^|\n)\S+\.rb:\d+:in `/) || output.include?("\n\tfrom ")

  record_failure(name, "unexpected Ruby stacktrace", output)
end

def run_cmd(*args)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, *args.map(&:to_s))
  [status.exitstatus, stdout + stderr]
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

def record_for(root, provider:, contract_id:, contract_kind:, event:, provider_action: "block")
  return decision_output_record_for(root, provider: provider, contract_id: contract_id, event: event, provider_action: provider_action) if contract_kind == "decision-output"

  fixture = fixture_file(root, provider, "#{contract_kind}/#{event}/#{contract_id}.txt", "#{contract_id}\n")
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => "1.0.0",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => contract_kind,
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => [fixture_hash_entry(root, fixture)],
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => {
      "mode" => "exact",
      "min_version" => "1.0.0",
      "max_version" => "1.0.0",
      "version_comparator" => "",
      "provider_build_hashes" => []
    },
    "fixture_record_hash" => ""
  }
  surface_hash = Digest::SHA256.hexdigest(JSON.generate(record.fetch("fixture_file_hashes")))
  case contract_kind
  when "command-execution"
    record["command_execution_contract_hash"] = surface_hash
  when "decision-output"
    record["decision_contract_hash"] = surface_hash
  when "worker-invocation"
    record["decision_contract_hash"] = surface_hash
    record["command_execution_contract_hash"] = surface_hash
  end
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def decision_output_record_for(root, provider:, contract_id:, event:, provider_action: "block")
  dir = root.join("providers/#{provider}/fixtures/decision-output/#{event}")
  blocks_or_denies = %w[block deny].include?(provider_action) ? 1 : 0
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
    "blocks_or_denies" => blocks_or_denies,
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
    "provider_version" => "1.0.0",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => "decision-output",
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => metadata.fetch("decision_contract_hash"),
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => [metadata_path, stdout_path, stderr_path, exit_code_path].map { |path| fixture_hash_entry(root, path) }.sort_by { |item| item.fetch("path") },
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => {
      "mode" => "exact",
      "min_version" => "1.0.0",
      "max_version" => "1.0.0",
      "version_comparator" => "",
      "provider_build_hashes" => []
    },
    "fixture_record_hash" => ""
  }
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def unknown_only(record)
  copy = JSON.parse(JSON.generate(record))
  copy["provider_version"] = "unknown"
  copy["compatibility_range"] = {
    "mode" => "unknown-only",
    "min_version" => "unknown",
    "max_version" => "unknown",
    "version_comparator" => "",
    "provider_build_hashes" => []
  }
  copy["fixture_record_hash"] = StrictModeFixtures.hash_record(copy, "fixture_record_hash")
  copy
end

def range_compatible(record)
  copy = JSON.parse(JSON.generate(record))
  copy["provider_version"] = "1.0.0"
  copy["compatibility_range"] = {
    "mode" => "range",
    "min_version" => "1.0.0",
    "max_version" => "2.0.0",
    "version_comparator" => "provider.semver-range",
    "provider_build_hashes" => []
  }
  copy["fixture_record_hash"] = StrictModeFixtures.hash_record(copy, "fixture_record_hash")
  copy
end

def import_codex_payload(root, event)
  source = root.join("capture/#{event}.json")
  source.dirname.mkpath
  source.write(JSON.generate({
    "event" => event,
    "thread_id" => "t1",
    "tool_name" => event == "pre-tool-use" ? "apply_patch" : nil,
    "tool_input" => event == "pre-tool-use" ? { "patch" => "*** Begin Patch\n*** Add File: lib/#{event}.rb\n+puts 1\n*** End Patch\n" } : nil
  }.compact) + "\n")
  project = root.join("project")
  cwd = project.join("src")
  cwd.mkpath
  run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", event, "--source", source, "--cwd", cwd, "--project-dir", project, "--captured-at", "2026-05-06T00:00:00Z")
end

def write_manifest(root, provider, records)
  StrictModeFixtures.write_manifest(StrictModeFixtures.manifest_path(root, provider), {
    "schema_version" => 1,
    "generated_at" => "2026-05-06T00:00:00Z",
    "records" => records,
    "manifest_hash" => ""
  })
end

def with_root
  $cases += 1
  Dir.mktmpdir("strict-fixture-readiness-") do |dir|
    root = Pathname.new(dir)
    %w[claude codex].each { |provider| root.join("providers/#{provider}/fixtures").mkpath }
    write_manifest(root, "claude", [])
    write_manifest(root, "codex", [])
    yield root
  end
end

with_root do |root|
  name = "empty manifests fail enforcing readiness with concrete missing proofs"
  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 1, got #{status}", output) unless status == 1
  record_failure(name, "missing event-order diagnostic", output) unless output.include?("missing codex event-order fixture")
  record_failure(name, "missing payload diagnostic", output) unless output.include?("missing codex stop payload-schema fixture")
  record_failure(name, "missing decision-output diagnostic", output) unless output.include?("missing codex stop decision-output fixture")
end

with_root do |root|
  name = "fixture manifest records summarize selected fixture proofs"
  record = record_for(root, provider: "claude", contract_id: "claude.stop.command", contract_kind: "command-execution", event: "stop")
  worker_record = record_for(root, provider: "claude", contract_id: "claude.worker.file-review", contract_kind: "worker-invocation", event: "worker:file-review")
  write_manifest(root, "claude", [record, worker_record])
  summary = StrictModeFixtureReadiness.fixture_manifest_records(root, ["claude"])
  if summary.length == 2
    item = summary.find { |entry| entry.fetch("contract_id") == "claude.stop.command" }
    worker_item = summary.find { |entry| entry.fetch("contract_id") == "claude.worker.file-review" }
    manifest = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "claude"))
    record_failure(name, "missing command summary", summary.inspect) unless item
    record_failure(name, "missing worker summary", summary.inspect) unless worker_item
    if item
      record_failure(name, "wrong provider", summary.inspect) unless item.fetch("provider") == "claude"
      record_failure(name, "wrong contract id", summary.inspect) unless item.fetch("contract_id") == "claude.stop.command"
      record_failure(name, "wrong fixture manifest hash", summary.inspect) unless item.fetch("fixture_manifest_hash") == manifest.fetch("manifest_hash")
      record_failure(name, "wrong fixture record hash", summary.inspect) unless item.fetch("fixture_record_hash") == record.fetch("fixture_record_hash")
    end
    if worker_item
      record_failure(name, "wrong worker contract kind", summary.inspect) unless worker_item.fetch("contract_kind") == "worker-invocation"
      record_failure(name, "wrong worker fixture record hash", summary.inspect) unless worker_item.fetch("fixture_record_hash") == worker_record.fetch("fixture_record_hash")
    end
  else
    record_failure(name, "expected two summary records", summary.inspect)
  end
end

with_root do |root|
  name = "enforceable fixture identity respects exact and unknown-only versions"
  exact = record_for(root, provider: "claude", contract_id: "claude.stop.command", contract_kind: "command-execution", event: "stop")
  unknown = unknown_only(exact)
  range = range_compatible(exact)
  record_failure(name, "exact record should match known installed version") unless StrictModeFixtureReadiness.enforceable_record?(exact, "1.0.0")
  record_failure(name, "exact record should not match unknown installed version") if StrictModeFixtureReadiness.enforceable_record?(exact, "unknown")
  record_failure(name, "unknown-only record should match unknown installed version") unless StrictModeFixtureReadiness.enforceable_record?(unknown, "unknown")
  record_failure(name, "unknown-only record should not match known installed version") if StrictModeFixtureReadiness.enforceable_record?(unknown, "1.0.0")
  record_failure(name, "range record must not be enforceable before comparator implementation") if StrictModeFixtureReadiness.enforceable_record?(range, "1.5.0")
end

with_root do |root|
  name = "unknown-only readiness records can satisfy unknown installed version"
  payload_records = []
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    status, output = import_codex_payload(root, event)
    assert_no_stacktrace("#{name} import #{event}", output)
    if status.zero?
      payload_records = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records")
    else
      record_failure(name, "payload import failed for #{event}", output)
    end
  end
  records = [
    unknown_only(record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start")),
    unknown_only(record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use"))
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << unknown_only(record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event))
  end
  %w[pre-tool-use stop].each do |event|
    records << unknown_only(record_for(root, provider: "codex", contract_id: "codex.#{event}.decision", contract_kind: "decision-output", event: event))
  end
  records << unknown_only(record_for(root, provider: "codex", contract_id: "codex.pre-tool-use.deny", contract_kind: "decision-output", event: "pre-tool-use", provider_action: "deny"))
  write_manifest(root, "codex", payload_records + records)
  errors = StrictModeFixtureReadiness.enforcing_errors(root, ["codex"])
  record_failure(name, "expected unknown-only readiness to pass", errors.join("\n")) unless errors.empty?
  selected = StrictModeFixtureReadiness.selected_output_contracts(root, ["codex"])
  selected_ids = selected.map { |record| [record.fetch("event"), record.fetch("contract_id"), record.fetch("provider_action")] }
  expected_ids = [
    ["pre-tool-use", "codex.pre-tool-use.decision", "block"],
    ["stop", "codex.stop.decision", "block"]
  ]
  record_failure(name, "selected output contracts mismatch", selected.inspect) unless selected_ids == expected_ids
  manifest_hash = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("manifest_hash")
  record_failure(name, "selected output contracts missing manifest hash", selected.inspect) unless selected.all? { |record| record.fetch("fixture_manifest_hash") == manifest_hash }
end

with_root do |root|
  name = "optional permission-request decision-output is selected when present"
  status, output = import_codex_payload(root, "permission-request")
  assert_no_stacktrace("#{name} import", output)
  payload_records = if status.zero?
                      StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records")
                    else
                      record_failure(name, "payload import failed for permission-request", output)
                      []
                    end
  permission_command = unknown_only(record_for(root, provider: "codex", contract_id: "codex.permission-request.command", contract_kind: "command-execution", event: "permission-request"))
  permission_decision = unknown_only(record_for(root, provider: "codex", contract_id: "codex.permission-request.deny", contract_kind: "decision-output", event: "permission-request", provider_action: "deny"))
  write_manifest(root, "codex", payload_records + [permission_command, permission_decision])

  selected = StrictModeFixtureReadiness.selected_output_contracts(root, ["codex"])
  selected_ids = selected.map { |record| [record.fetch("event"), record.fetch("contract_id"), record.fetch("provider_action")] }
  expected_ids = [["permission-request", "codex.permission-request.deny", "deny"]]
  record_failure(name, "permission selected output mismatch", selected.inspect) unless selected_ids == expected_ids

  errors = StrictModeFixtureReadiness.enforcing_errors(root, ["codex"])
  record_failure(name, "permission-request must not become a required v0 readiness fixture", errors.join("\n")) if errors.any? { |error| error.include?("missing codex permission-request") }
end

with_root do |root|
  name = "optional permission-request decision-output alone is not selected"
  permission = unknown_only(record_for(root, provider: "codex", contract_id: "codex.permission-request.deny", contract_kind: "decision-output", event: "permission-request", provider_action: "deny"))
  write_manifest(root, "codex", [permission])

  selected = StrictModeFixtureReadiness.selected_output_contracts(root, ["codex"])
  record_failure(name, "permission decision-output was selected without payload/command proof", selected.inspect) if selected.any? { |record| record.fetch("event") == "permission-request" }
end

with_root do |root|
  name = "blocking events require block or deny decision-output fixtures"
  payload_records = []
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    status, output = import_codex_payload(root, event)
    assert_no_stacktrace("#{name} import #{event}", output)
    if status.zero?
      payload_records = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records")
    else
      record_failure(name, "payload import failed for #{event}", output)
    end
  end
  records = [
    unknown_only(record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start")),
    unknown_only(record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use"))
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << unknown_only(record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event))
  end
  records << unknown_only(record_for(root, provider: "codex", contract_id: "codex.pre.warn", contract_kind: "decision-output", event: "pre-tool-use", provider_action: "warn"))
  records << unknown_only(record_for(root, provider: "codex", contract_id: "codex.stop.block", contract_kind: "decision-output", event: "stop"))
  write_manifest(root, "codex", payload_records + records)

  errors = StrictModeFixtureReadiness.enforcing_errors(root, ["codex"])
  expected = "missing codex pre-tool-use decision-output fixture with block/deny provider output"
  record_failure(name, "missing block/deny readiness diagnostic", errors.join("\n")) unless errors.include?(expected)
  record_failure(name, "stop block fixture should satisfy readiness", errors.join("\n")) if errors.any? { |error| error.include?("missing codex stop decision-output") }
end

with_root do |root|
  name = "malformed fixture manifest readiness failure is controlled"
  path = StrictModeFixtures.manifest_path(root, "codex")
  manifest = JSON.parse(path.read)
  manifest["manifest_hash"] = "bad"
  path.write(JSON.pretty_generate(manifest) + "\n")
  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 1, got #{status}", output) unless status == 1
  record_failure(name, "missing manifest invalid diagnostic", output) unless output.include?("fixture manifest invalid for codex")
  record_failure(name, "missing hash mismatch diagnostic", output) unless output.include?("manifest_hash mismatch")
end

if $failures.empty?
  puts "fixture readiness tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
