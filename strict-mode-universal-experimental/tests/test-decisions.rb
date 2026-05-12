#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/decision_contract_lib"

ROOT = StrictModeMetadata.project_root
VALIDATOR = ROOT.join("tools/validate-decision-contract.rb")
FIXTURE_VALIDATOR = ROOT.join("tools/validate-fixtures.rb")

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

def with_root
  $cases += 1
  Dir.mktmpdir("strict-decisions-") do |dir|
    root = Pathname.new(dir)
    %w[claude codex].each { |provider| root.join("providers/#{provider}/fixtures").mkpath }
    write_manifest(root, "claude", [])
    write_manifest(root, "codex", [])
    yield root
  end
end

def write_manifest(root, provider, records)
  StrictModeFixtures.write_manifest(StrictModeFixtures.manifest_path(root, provider), {
    "schema_version" => 1,
    "generated_at" => "2026-05-06T00:00:00Z",
    "records" => records,
    "manifest_hash" => ""
  })
end

def write_json(path, record)
  path.dirname.mkpath
  path.write(JSON.pretty_generate(record) + "\n")
  path
end

def provider_output_metadata(
  provider: "claude",
  event: "stop",
  contract_id: "claude.stop.block",
  provider_action: "block",
  stdout_mode: "json",
  stdout_required_fields: %w[decision reason],
  stderr_mode: "empty",
  stderr_required_fields: [],
  exit_code: 0
)
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "event" => event,
    "logical_event" => event,
    "provider_action" => provider_action,
    "stdout_mode" => stdout_mode,
    "stdout_required_fields" => stdout_required_fields,
    "stderr_mode" => stderr_mode,
    "stderr_required_fields" => stderr_required_fields,
    "exit_code" => exit_code,
    "blocks_or_denies" => %w[block deny].include?(provider_action) ? 1 : 0,
    "injects_context" => provider_action == "inject" ? 1 : 0,
    "decision_contract_hash" => ""
  }
  record["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(record)
  record
end

def internal_decision(action: "block", reason: "blocked", severity: "error", additional_context: "")
  {
    "schema_version" => 1,
    "action" => action,
    "reason" => reason,
    "severity" => severity,
    "additional_context" => additional_context,
    "metadata" => {}
  }
end

def fixture_hash_entry(root, path)
  {
    "path" => path.relative_path_from(root).to_s,
    "content_sha256" => Digest::SHA256.file(path).hexdigest
  }
end

def decision_output_record(root, provider: "claude", event: "stop", contract_id: "claude.stop.block")
  dir = root.join("providers/#{provider}/fixtures/decision-output/#{event}")
  metadata = provider_output_metadata(provider: provider, event: event, contract_id: contract_id)
  metadata_path = write_json(dir.join("#{contract_id}.provider-output.json"), metadata)
  stdout_path = dir.join("#{contract_id}.stdout")
  stdout_path.write("{\"decision\":\"block\",\"reason\":\"blocked\"}\n")
  stderr_path = dir.join("#{contract_id}.stderr")
  stderr_path.write("")
  exit_code_path = dir.join("#{contract_id}.exit-code")
  exit_code_path.write("0\n")
  files = [metadata_path, stdout_path, stderr_path, exit_code_path]
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
    "fixture_file_hashes" => files.map { |path| fixture_hash_entry(root, path) }.sort_by { |item| item.fetch("path") },
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
  [record, metadata_path, stdout_path, stderr_path, exit_code_path]
end

with_root do |root|
  name = "valid internal decisions validate"
  [
    { "schema_version" => 1, "action" => "allow", "reason" => "", "severity" => "info", "additional_context" => "", "metadata" => {} },
    { "schema_version" => 1, "action" => "warn", "reason" => "careful", "severity" => "warning", "additional_context" => "", "metadata" => { "gate" => "static" } },
    { "schema_version" => 1, "action" => "block", "reason" => "blocked", "severity" => "error", "additional_context" => "", "metadata" => { "evidence_hash" => "a" * 64 } },
    { "schema_version" => 1, "action" => "inject", "reason" => "", "severity" => "info", "additional_context" => "context", "metadata" => {} }
  ].each_with_index do |decision, index|
    path = write_json(root.join("decision-#{index}.json"), decision)
    status, output = run_cmd(VALIDATOR, "--internal", path)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected valid decision #{index}, got #{status}", output) unless status.zero?
  end
end

with_root do |root|
  name = "invalid internal decisions are rejected"
  cases = [
    [{ "schema_version" => 1, "action" => "allow", "reason" => "text", "severity" => "info", "additional_context" => "", "metadata" => {} }, "allow reason must be empty"],
    [{ "schema_version" => 1, "action" => "block", "reason" => "", "severity" => "error", "additional_context" => "", "metadata" => {} }, "block reason must be non-empty"],
    [{ "schema_version" => 1, "action" => "inject", "reason" => "", "severity" => "info", "additional_context" => "", "metadata" => {} }, "inject additional_context must be non-empty"],
    [{ "schema_version" => 1, "action" => "warn", "reason" => "", "severity" => "info", "additional_context" => "x", "metadata" => {} }, "warn reason must be non-empty"],
    [{ "schema_version" => 1, "action" => "warn", "reason" => "x", "severity" => "info", "additional_context" => "", "metadata" => {} }, "warn severity must be warning"],
    [{ "schema_version" => 1, "action" => "allow", "reason" => "", "severity" => "info", "additional_context" => "", "metadata" => { "raw_payload" => "secret" } }, "unsafe metadata key"]
  ]
  cases.each_with_index do |(decision, expected), index|
    path = write_json(root.join("invalid-#{index}.json"), decision)
    status, output = run_cmd(VALIDATOR, "--internal", path)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected invalid decision #{index}, got #{status}", output) unless status == 1
    record_failure(name, "missing diagnostic #{expected.inspect}", output) unless output.include?(expected)
  end
end

with_root do |root|
  name = "provider output metadata validates with captured output"
  _record, metadata_path, stdout_path, stderr_path = decision_output_record(root)
  status, output = run_cmd(VALIDATOR, "--provider-output", metadata_path, "--stdout", stdout_path, "--stderr", stderr_path, "--exit-code", "0")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected provider output validation success", output) unless status.zero?
end

with_root do |_root|
  name = "provider output emission renders fixture-bound JSON block"
  metadata = provider_output_metadata
  decision = internal_decision(reason: "delete blocked")
  emitted = StrictModeDecisionContract.emit_provider_output(metadata, decision)
  parsed = JSON.parse(emitted.fetch("stdout"))
  record_failure(name, "stdout decision mismatch", emitted.inspect) unless parsed.fetch("decision") == "block"
  record_failure(name, "stdout reason mismatch", emitted.inspect) unless parsed.fetch("reason") == "delete blocked"
  record_failure(name, "stderr should be empty", emitted.inspect) unless emitted.fetch("stderr") == ""
  record_failure(name, "exit code mismatch", emitted.inspect) unless emitted.fetch("exit_code") == 0
end

with_root do |_root|
  name = "provider output emission renders plain-text injection"
  metadata = provider_output_metadata(
    contract_id: "claude.user-prompt.inject",
    event: "user-prompt-submit",
    provider_action: "inject",
    stdout_mode: "plain-text",
    stdout_required_fields: []
  )
  decision = internal_decision(action: "inject", reason: "", severity: "info", additional_context: "strict reminder")
  emitted = StrictModeDecisionContract.emit_provider_output(metadata, decision)
  record_failure(name, "plain text context mismatch", emitted.inspect) unless emitted.fetch("stdout") == "strict reminder"
  record_failure(name, "stderr should be empty", emitted.inspect) unless emitted.fetch("stderr") == ""
end

with_root do |_root|
  name = "provider output emission rejects incompatible action"
  metadata = provider_output_metadata
  decision = internal_decision(action: "allow", reason: "", severity: "info")
  begin
    StrictModeDecisionContract.emit_provider_output(metadata, decision)
    record_failure(name, "expected incompatible action rejection")
  rescue RuntimeError => e
    record_failure(name, "wrong rejection", e.message) unless e.message.include?("not compatible")
  end
end

with_root do |_root|
  name = "provider output emission rejects unsupported JSON fields"
  metadata = provider_output_metadata(stdout_required_fields: %w[provider_decision])
  decision = internal_decision(reason: "blocked")
  begin
    StrictModeDecisionContract.emit_provider_output(metadata, decision)
    record_failure(name, "expected unsupported field rejection")
  rescue RuntimeError => e
    record_failure(name, "wrong rejection", e.message) unless e.message.include?("unsupported provider output field")
  end
end

with_root do |root|
  name = "provider output metadata rejects hash and mode drift"
  metadata = provider_output_metadata
  metadata["stdout_required_fields"] = %w[reason decision]
  path = write_json(root.join("bad-provider-output.json"), metadata)
  status, output = run_cmd(VALIDATOR, "--provider-output", path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected invalid provider output, got #{status}", output) unless status == 1
  record_failure(name, "missing sorted-field diagnostic", output) unless output.include?("stdout_required_fields must be a sorted unique string array")
  record_failure(name, "missing hash diagnostic", output) unless output.include?("decision_contract_hash mismatch")
end

with_root do |root|
  name = "provider output metadata rejects effectless block"
  metadata = provider_output_metadata
  metadata["stdout_mode"] = "empty"
  metadata["stdout_required_fields"] = []
  metadata["stderr_mode"] = "empty"
  metadata["stderr_required_fields"] = []
  metadata["exit_code"] = 0
  metadata["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(metadata)
  path = write_json(root.join("effectless-block.json"), metadata)
  status, output = run_cmd(VALIDATOR, "--provider-output", path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected invalid provider output, got #{status}", output) unless status == 1
  record_failure(name, "missing effectless block diagnostic", output) unless output.include?("block/deny provider_action requires a non-empty output mode or non-zero exit_code")
end

with_root do |root|
  name = "provider output metadata rejects empty event"
  metadata = provider_output_metadata
  metadata["event"] = ""
  metadata["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(metadata)
  path = write_json(root.join("empty-event.json"), metadata)
  status, output = run_cmd(VALIDATOR, "--provider-output", path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected invalid provider output, got #{status}", output) unless status == 1
  record_failure(name, "missing empty event diagnostic", output) unless output.include?("event must be a non-empty string")
end

with_root do |root|
  name = "captured provider output drift is rejected"
  _record, metadata_path, stdout_path, stderr_path = decision_output_record(root)
  stdout_path.write("{\"decision\":\"block\"}\n")
  status, output = run_cmd(VALIDATOR, "--provider-output", metadata_path, "--stdout", stdout_path, "--stderr", stderr_path, "--exit-code", "0")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected capture validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing required field diagnostic", output) unless output.include?("captured stdout JSON missing required field reason")
end

with_root do |root|
  name = "captured provider output rejects empty text block with zero exit"
  metadata = provider_output_metadata
  metadata["stdout_mode"] = "plain-text"
  metadata["stdout_required_fields"] = []
  metadata["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(metadata)
  metadata_path = write_json(root.join("plain-block.json"), metadata)
  stdout_path = root.join("empty.stdout")
  stdout_path.write("")
  stderr_path = root.join("empty.stderr")
  stderr_path.write("")
  status, output = run_cmd(VALIDATOR, "--provider-output", metadata_path, "--stdout", stdout_path, "--stderr", stderr_path, "--exit-code", "0")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected capture validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing empty capture diagnostic", output) unless output.include?("captured block/deny output must contain stdout/stderr bytes or use non-zero exit_code")
end

with_root do |_root|
  name = "captured provider output rejects non-integer exit code without raising"
  metadata = provider_output_metadata
  errors = StrictModeDecisionContract.validate_captured_output(
    metadata,
    stdout_bytes: "{\"decision\":\"block\",\"reason\":\"blocked\"}\n",
    stderr_bytes: "",
    exit_code: nil
  )
  record_failure(name, "missing non-integer exit-code diagnostic", errors.inspect) unless errors.include?("captured exit_code must be an integer")
end

with_root do |root|
  name = "invalid CLI exit-code is a usage error"
  metadata = provider_output_metadata
  metadata_path = write_json(root.join("provider-output.json"), metadata)
  status, output = run_cmd(VALIDATOR, "--provider-output", metadata_path, "--exit-code", "not-a-number")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected usage error, got #{status}", output) unless status == 2
  record_failure(name, "missing exit-code usage diagnostic", output) unless output.include?("--exit-code must be an integer")
end

with_root do |root|
  name = "decision-output fixture record validates"
  record, _metadata_path, _stdout_path, _stderr_path = decision_output_record(root)
  write_manifest(root, "claude", [record])
  status, output = run_cmd(FIXTURE_VALIDATOR, "--root", root)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected fixture validation success", output) unless status.zero?
end

with_root do |root|
  name = "decision-output fixture rejects metadata logical-event mismatch"
  record, metadata_path, _stdout_path, _stderr_path = decision_output_record(root)
  metadata = JSON.parse(metadata_path.read)
  metadata["logical_event"] = "pre-tool-use"
  metadata["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(metadata)
  metadata_path.write(JSON.pretty_generate(metadata) + "\n")
  entry = record.fetch("fixture_file_hashes").find { |item| item.fetch("path").end_with?(".provider-output.json") }
  entry["content_sha256"] = Digest::SHA256.file(metadata_path).hexdigest
  record["decision_contract_hash"] = metadata.fetch("decision_contract_hash")
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "claude", [record])
  status, output = run_cmd(FIXTURE_VALIDATOR, "--root", root)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected fixture validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing logical_event binding diagnostic", output) unless output.include?("provider_output logical_event must match fixture record event")
end

with_root do |root|
  name = "decision-output fixture rejects metadata event mismatch"
  record, metadata_path, _stdout_path, _stderr_path = decision_output_record(root)
  metadata = JSON.parse(metadata_path.read)
  metadata["event"] = "provider-native-stop"
  metadata["decision_contract_hash"] = StrictModeDecisionContract.provider_output_hash(metadata)
  metadata_path.write(JSON.pretty_generate(metadata) + "\n")
  entry = record.fetch("fixture_file_hashes").find { |item| item.fetch("path").end_with?(".provider-output.json") }
  entry["content_sha256"] = Digest::SHA256.file(metadata_path).hexdigest
  record["decision_contract_hash"] = metadata.fetch("decision_contract_hash")
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "claude", [record])
  status, output = run_cmd(FIXTURE_VALIDATOR, "--root", root)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected fixture validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing event binding diagnostic", output) unless output.include?("provider_output event must match fixture record event")
end

with_root do |root|
  name = "decision-output fixture rejects cross-contract capture filenames"
  record, _metadata_path, _stdout_path, _stderr_path, _exit_code_path = decision_output_record(root)
  wrong_stdout = root.join("providers/claude/fixtures/decision-output/stop/other.contract.stdout")
  wrong_stdout.write("{\"decision\":\"block\",\"reason\":\"blocked\"}\n")
  stdout_entry = record.fetch("fixture_file_hashes").find { |item| item.fetch("path").end_with?(".stdout") }
  stdout_entry["path"] = wrong_stdout.relative_path_from(root).to_s
  stdout_entry["content_sha256"] = Digest::SHA256.file(wrong_stdout).hexdigest
  record["fixture_file_hashes"] = record.fetch("fixture_file_hashes").sort_by { |item| item.fetch("path") }
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "claude", [record])
  status, output = run_cmd(FIXTURE_VALIDATOR, "--root", root)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected fixture validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing exact stdout diagnostic", output) unless output.include?("decision-output must include exactly one stdout fixture")
  record_failure(name, "missing extra file diagnostic", output) unless output.include?("decision-output must not include extra fixture files")
end

with_root do |root|
  name = "decision-output fixture rejects symlink metadata without reading target"
  record, metadata_path, _stdout_path, _stderr_path, _exit_code_path = decision_output_record(root)
  metadata_path.delete
  target = root.join("outside-provider-output.json")
  target.write("not json\n")
  File.symlink(target, metadata_path)
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "claude", [record])
  status, output = run_cmd(FIXTURE_VALIDATOR, "--root", root)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected fixture validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing symlink diagnostic", output) unless output.include?("existing non-symlink fixture file")
  record_failure(name, "symlink target should not be parsed", output) if output.include?("provider_output must be duplicate-key-safe JSON")
end

if $failures.empty?
  puts "decision contract tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
