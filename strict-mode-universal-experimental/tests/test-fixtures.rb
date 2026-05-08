#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/decision_contract_lib"
require_relative "../tools/fixture_manifest_lib"
require_relative "../tools/provider_detection_lib"

ROOT = StrictModeMetadata.project_root
VALIDATOR = ROOT.join("tools/validate-fixtures.rb")
GENERATOR = ROOT.join("tools/generate-fixture-manifests.rb")
IMPORTER = ROOT.join("tools/import-discovery-fixture.rb")
CONTRACT_IMPORTER = ROOT.join("tools/import-contract-fixture.rb")
RAW_CAPTURE_IMPORTER = ROOT.join("tools/import-raw-captures.rb")
NORMALIZER = ROOT.join("tools/normalize-event.rb")
PROVIDER_VERIFY = ROOT.join("tools/verify-provider-payload.rb")

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

def read_json(path)
  JSON.parse(path.read)
end

def write_manifest(root, provider, records)
  path = StrictModeFixtures.manifest_path(root, provider)
  manifest = {
    "schema_version" => 1,
    "generated_at" => "2026-05-06T00:00:00Z",
    "records" => records,
    "manifest_hash" => ""
  }
  StrictModeFixtures.write_manifest(path, manifest)
end

def write_raw_manifest(root, provider, manifest)
  StrictModeFixtures.manifest_path(root, provider).write(JSON.pretty_generate(manifest) + "\n")
end

def fixture_file(root, provider, relative_name, content)
  path = Pathname.new(root).join("providers/#{provider}/fixtures/#{relative_name}")
  path.dirname.mkpath
  path.write(content)
  path
end

def fixture_hash_entry(root, path)
  relative = path.relative_path_from(Pathname.new(root)).to_s
  {
    "path" => relative,
    "content_sha256" => Digest::SHA256.file(path).hexdigest
  }
end

def typed_contract_proof(provider:, contract_kind:, event:, contract_id:, provider_version: "1.0.0", provider_build_hash: "")
  payload_hash = Digest::SHA256.hexdigest("#{provider}:#{event}:payload")
  case contract_kind
  when "command-execution"
    {
      "schema_version" => 1,
      "proof_kind" => "#{provider}.command-execution.observed",
      "provider" => provider,
      "provider_version" => provider_version,
      "provider_build_hash" => provider_build_hash,
      "event" => event,
      "contract_id" => contract_id,
      "hook_command_executed" => true,
      "hook_argv" => ["strict-hook", "--provider", provider, event],
      "hook_exit_status" => 0,
      "stdout_sha256" => Digest::SHA256.hexdigest(""),
      "stderr_sha256" => Digest::SHA256.hexdigest(""),
      "discovery_recorded_at" => "2026-05-06T00:00:00Z",
      "provider_detection_decision" => "match",
      "payload_sha256" => payload_hash,
      "raw_payload_captured" => true,
      "raw_payload_path" => "/tmp/#{payload_hash[0, 12]}.payload",
      "hook_mode" => "discovery-log-only"
    }
  when "event-order"
    {
      "schema_version" => 1,
      "proof_kind" => "#{provider}.event-order.observed",
      "provider" => provider,
      "provider_version" => provider_version,
      "provider_build_hash" => provider_build_hash,
      "event" => event,
      "contract_id" => contract_id,
      "early_baseline_events_before_tool" => true,
      "observed_order" => [
        { "event" => event, "recorded_at" => "2026-05-06T00:00:00Z", "payload_sha256" => payload_hash },
        { "event" => "pre-tool-use", "recorded_at" => "2026-05-06T00:00:01Z", "payload_sha256" => Digest::SHA256.hexdigest("#{provider}:pre") }
      ]
    }
  when "matcher"
    {
      "schema_version" => 1,
      "proof_kind" => "#{provider}.matcher.observed",
      "provider" => provider,
      "provider_version" => provider_version,
      "provider_build_hash" => provider_build_hash,
      "event" => event,
      "contract_id" => contract_id,
      "matcher" => ".*",
      "matched_tool_event" => true,
      "provider_detection_decision" => "match",
      "payload_sha256" => payload_hash,
      "raw_payload_path" => "/tmp/#{payload_hash[0, 12]}.payload",
      "preflight_trusted" => true,
      "tool_kind" => "shell"
    }
  else
    { "schema_version" => 1, "contract_id" => contract_id }
  end
end

def typed_fixture_file(root, provider:, contract_kind:, event:, contract_id:, provider_version: "1.0.0", provider_build_hash: "")
  fixture_file(
    root,
    provider,
    "#{contract_kind}/#{event}/#{contract_id}.#{contract_kind}.json",
    JSON.pretty_generate(typed_contract_proof(
      provider: provider,
      contract_kind: contract_kind,
      event: event,
      contract_id: contract_id,
      provider_version: provider_version,
      provider_build_hash: provider_build_hash
    )) + "\n"
  )
end

def raw_payload_fixture(root, provider, event, body = nil)
  body ||= JSON.generate({ "event" => event, "thread_id" => "t1" }) + "\n"
  hash = Digest::SHA256.hexdigest(body)
  path = fixture_file(root, provider, "payloads/#{event}/#{hash[0, 16]}.json", body)
  proof = {
    "schema_version" => 1,
    "provider_arg" => provider,
    "provider_arg_source" => "fixture-import",
    "payload_sha256" => hash,
    "detected_provider" => provider,
    "decision" => "match",
    "claude_indicators" => [],
    "codex_indicators" => [],
    "conflict_indicators" => [],
    "fixture_usable" => true,
    "enforcement_usable" => false,
    "diagnostic" => "test provider proof",
    "provider_proof_hash" => ""
  }
  proof["provider_proof_hash"] = StrictModeMetadata.hash_record(proof, "provider_proof_hash")
  fixture_file(root, provider, "provider-proof/#{event}/#{hash[0, 16]}.provider-detection.json", JSON.pretty_generate(proof) + "\n")
  [path, hash, proof.fetch("provider_proof_hash")]
end

def bound_typed_proof(provider:, contract_kind:, event:, contract_id:, payload_hash:, provider_version: "1.0.0", provider_build_hash: "")
  proof = typed_contract_proof(
    provider: provider,
    contract_kind: contract_kind,
    event: event,
    contract_id: contract_id,
    provider_version: provider_version,
    provider_build_hash: provider_build_hash
  )
  case contract_kind
  when "command-execution", "matcher"
    proof["payload_sha256"] = payload_hash
    proof["raw_payload_path"] = "/captures/#{payload_hash[0, 12]}.payload"
  when "event-order"
    proof["observed_order"].each do |item|
      item["payload_sha256"] = payload_hash if item["event"] == event
    end
  end
  proof
end

def discovery_record_for(proof, event, provider_proof_hash: "0" * 64)
  {
    "schema_version" => 1,
    "recorded_at" => proof["discovery_recorded_at"] || "2026-05-06T00:00:00Z",
    "provider" => proof.fetch("provider"),
    "event" => event,
    "mode" => proof["hook_mode"] || "discovery-log-only",
    "provider_detection_decision" => proof.fetch("provider_detection_decision", "match"),
    "provider_proof_hash" => provider_proof_hash,
    "payload_sha256" => proof.fetch("payload_sha256"),
    "raw_payload_captured" => proof.fetch("raw_payload_captured", true),
    "raw_payload_path" => proof.fetch("raw_payload_path", "/captures/#{proof.fetch("payload_sha256")[0, 12]}.payload")
  }
end

def bound_matcher_fixture_paths(root, provider:, event:, contract_id:, provider_version: "1.0.0")
  _raw, payload_hash, provider_proof_hash = raw_payload_fixture(root, provider, event)
  proof = bound_typed_proof(provider: provider, contract_kind: "matcher", event: event, contract_id: contract_id, payload_hash: payload_hash, provider_version: provider_version)
  proof_path = fixture_file(root, provider, "matcher/#{event}/#{contract_id}.matcher.json", JSON.pretty_generate(proof) + "\n")
  discovery_path = fixture_file(root, provider, "matcher/#{event}/#{contract_id}.discovery-record.json", JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_proof_hash)) + "\n")
  [proof_path, discovery_path]
end

def record_for(root, provider:, contract_id:, contract_kind:, event:, fixture_paths:, provider_version: "1.0.0", compatibility: nil)
  hashes = fixture_paths.map { |path| fixture_hash_entry(root, path) }.sort_by { |item| item.fetch("path") }
  surface_hash = Digest::SHA256.hexdigest(JSON.generate(hashes))
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => provider_version,
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => contract_kind,
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => hashes,
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => compatibility || {
      "mode" => "exact",
      "min_version" => provider_version,
      "max_version" => provider_version,
      "version_comparator" => "",
      "provider_build_hashes" => []
    },
    "fixture_record_hash" => ""
  }
  case contract_kind
  when "payload-schema", "prompt-extraction"
    record["payload_schema_hash"] = surface_hash
  when "command-execution"
    proof = StrictModeFixtures.load_typed_contract_proof(fixture_paths.first)
    record["command_execution_contract_hash"] = StrictModeFixtures.typed_contract_proof_hash(record, proof)
  when "decision-output"
    record["decision_contract_hash"] = surface_hash
  when "judge-invocation", "worker-invocation"
    record["decision_contract_hash"] = surface_hash
    record["command_execution_contract_hash"] = surface_hash
  end
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def with_root
  $cases += 1
  Dir.mktmpdir("strict-fixtures-") do |dir|
    root = Pathname.new(dir)
    %w[claude codex].each { |provider| root.join("providers/#{provider}/fixtures").mkpath }
    write_manifest(root, "claude", [])
    write_manifest(root, "codex", [])
    yield root
  end
end

def expect_pass(name)
  with_root do |root|
    yield root
    exitstatus, output = run_cmd(VALIDATOR, "--root", root)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected exit 0, got #{exitstatus}", output) unless exitstatus.zero?
  end
end

def expect_fail(name, expected)
  with_root do |root|
    yield root
    exitstatus, output = run_cmd(VALIDATOR, "--root", root)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
    record_failure(name, "missing expected output #{expected.inspect}", output) unless output.include?(expected)
  end
end

def expect_import_fail(name, expected)
  with_root do |root|
    exitstatus, output = yield root
    assert_no_stacktrace(name, output)
    record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
    record_failure(name, "missing expected output #{expected.inspect}", output) unless output.include?(expected)
    validate_status, validate_output = run_cmd(VALIDATOR, "--root", root)
    assert_no_stacktrace(name, validate_output)
    record_failure(name, "import failure left invalid manifests", validate_output) unless validate_status.zero?
  end
end

def import_codex_payload_fixture(root, name)
  source = root.join("capture/#{name.gsub(/[^a-z0-9]+/i, "-")}.json")
  source.dirname.mkpath
  source.write("{\"event\":\"pre-tool-use\",\"thread_id\":\"t1\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Begin Patch\\n*** Add File: lib/new_file.rb\\n+puts 1\\n*** End Patch\\n\"}}\n")
  project = root.join("project")
  cwd = project.join("src")
  cwd.mkpath
  exitstatus, output = run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "pre-tool-use", "--source", source, "--cwd", cwd, "--project-dir", project, "--provider-version", "1.2.3", "--captured-at", "2026-05-06T00:00:00Z")
  [exitstatus, output, source]
end

expect_pass("checked-in fixture manifests validate") do |_root|
  exitstatus, output = run_cmd(VALIDATOR, "--root", ROOT)
  assert_no_stacktrace("checked-in fixture manifests validate", output)
  record_failure("checked-in fixture manifests validate", "expected root validation success", output) unless exitstatus.zero?
end

expect_pass("valid matcher fixture record validates") do |root|
  paths = bound_matcher_fixture_paths(root, provider: "claude", event: "stop", contract_id: "claude.stop.matcher")
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: paths)
  write_manifest(root, "claude", [record])
end

expect_pass("valid worker-invocation fixture record validates") do |root|
  path = fixture_file(root, "codex", "worker-invocation/file-review/output.json", "{\"output_kind\":\"findings\",\"advisory_only\":true}\n")
  record = record_for(root, provider: "codex", contract_id: "codex.worker.file-review", contract_kind: "worker-invocation", event: "worker:file-review", fixture_paths: [path])
  write_manifest(root, "codex", [record])
end

expect_pass("importer creates payload fixture record") do |root|
  source = root.join("capture/stop.json")
  source.dirname.mkpath
  source.write("{\"event\":\"pre-tool-use\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Begin Patch\\n*** Add File: lib/new_file.rb\\n+puts 1\\n*** End Patch\\n\"}}\n")
  project = root.join("project")
  cwd = project.join("src")
  cwd.mkpath
  exitstatus, output = run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "pre-tool-use", "--source", source, "--cwd", cwd, "--project-dir", project, "--provider-version", "1.2.3", "--captured-at", "2026-05-06T00:00:00Z")
  assert_no_stacktrace("importer creates payload fixture record", output)
  unless exitstatus.zero?
    record_failure("importer creates payload fixture record", "importer failed", output)
    next
  end
  manifest = read_json(StrictModeFixtures.manifest_path(root, "codex"))
  record = manifest.fetch("records").fetch(0)
  record_failure("importer creates payload fixture record", "wrong contract kind", output) unless record.fetch("contract_kind") == "payload-schema"
  record_failure("importer creates payload fixture record", "payload hash was not populated", output) if record.fetch("payload_schema_hash") == StrictModeFixtures::ZERO_HASH
  record_failure("importer creates payload fixture record", "wrong compatibility mode", output) unless record.fetch("compatibility_range").fetch("mode") == "exact"
  record_failure("importer creates payload fixture record", "wrong manifest event", output) unless record.fetch("event") == "pre-tool-use"
  hashes = record.fetch("fixture_file_hashes")
  record_failure("importer creates payload fixture record", "expected raw, normalized, and provider proof fixture files", output) unless hashes.size == 3
  normalized_entry = hashes.find { |item| item.fetch("path").include?("/normalized/") }
  provider_proof_entry = hashes.find { |item| item.fetch("path").include?("/provider-proof/") }
  record_failure("importer creates payload fixture record", "normalized fixture entry missing", output) unless normalized_entry
  record_failure("importer creates payload fixture record", "provider proof fixture entry missing", output) unless provider_proof_entry
  if normalized_entry
    normalized_path = root.join(normalized_entry.fetch("path"))
    record_failure("importer creates payload fixture record", "normalized fixture file missing", output) unless normalized_path.file?
    validate_status, validate_output = run_cmd(NORMALIZER, "--validate-normalized", normalized_path)
    assert_no_stacktrace("importer creates payload fixture record normalized validation", validate_output)
    record_failure("importer creates payload fixture record", "normalized artifact did not validate", validate_output) unless validate_status.zero?
    normalized = read_json(normalized_path)
    record_failure("importer creates payload fixture record", "normalized tool kind mismatch", output) unless normalized.fetch("tool").fetch("kind") == "patch"
    record_failure("importer creates payload fixture record", "normalized write intent mismatch", output) unless normalized.fetch("tool").fetch("write_intent") == "write"
  end
  if provider_proof_entry
    proof_path = root.join(provider_proof_entry.fetch("path"))
    record_failure("importer creates payload fixture record", "provider proof fixture file missing", output) unless proof_path.file?
    verify_status, verify_output = run_cmd(PROVIDER_VERIFY, "--validate-proof", proof_path)
    assert_no_stacktrace("importer creates payload fixture record provider proof validation", verify_output)
    record_failure("importer creates payload fixture record", "provider proof did not validate", verify_output) unless verify_status.zero?
    proof = read_json(proof_path)
    record_failure("importer creates payload fixture record", "provider proof did not match", output) unless proof.fetch("decision") == "match"
  end
end

expect_pass("contract importer creates generic readiness fixture records") do |root|
  _raw, payload_hash, provider_proof_hash = raw_payload_fixture(root, "codex", "pre-tool-use")
  source = root.join("capture/command-proof.json")
  source.dirname.mkpath
  command_proof = bound_typed_proof(provider: "codex", contract_kind: "command-execution", event: "pre-tool-use", contract_id: "codex.pre-tool-use.command", payload_hash: payload_hash, provider_version: "unknown")
  source.write(JSON.pretty_generate(command_proof) + "\n")
  command_discovery = root.join("capture/command-discovery.json")
  command_stdout = root.join("capture/command.stdout")
  command_stderr = root.join("capture/command.stderr")
  command_exit = root.join("capture/command.exit-code")
  command_discovery.write(JSON.pretty_generate(discovery_record_for(command_proof, "pre-tool-use", provider_proof_hash: provider_proof_hash)) + "\n")
  command_stdout.write("")
  command_stderr.write("")
  command_exit.write("0\n")
  status, output = run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "pre-tool-use",
    "--contract-kind", "command-execution",
    "--contract-id", "codex.pre-tool-use.command",
    "--source", source,
    "--discovery-record", command_discovery,
    "--stdout", command_stdout,
    "--stderr", command_stderr,
    "--exit-code", command_exit,
    "--captured-at", "2026-05-06T00:00:00Z"
  )
  assert_no_stacktrace("contract importer creates generic readiness fixture records", output)
  unless status.zero?
    record_failure("contract importer creates generic readiness fixture records", "command import failed", output)
    next
  end

  matcher = root.join("capture/matcher-proof.json")
  matcher_proof = bound_typed_proof(provider: "codex", contract_kind: "matcher", event: "pre-tool-use", contract_id: "codex.pre.matcher", payload_hash: payload_hash, provider_version: "unknown")
  matcher_discovery = root.join("capture/matcher-discovery.json")
  matcher.write(JSON.pretty_generate(matcher_proof) + "\n")
  matcher_discovery.write(JSON.pretty_generate(discovery_record_for(matcher_proof, "pre-tool-use", provider_proof_hash: provider_proof_hash)) + "\n")
  status, output = run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "pre-tool-use",
    "--contract-kind", "matcher",
    "--contract-id", "codex.pre.matcher",
    "--source", matcher,
    "--discovery-record", matcher_discovery,
    "--captured-at", "2026-05-06T00:00:00Z"
  )
  assert_no_stacktrace("contract importer creates generic readiness fixture records matcher", output)
  unless status.zero?
    record_failure("contract importer creates generic readiness fixture records", "matcher import failed", output)
    next
  end

  manifest = read_json(StrictModeFixtures.manifest_path(root, "codex"))
  command = manifest.fetch("records").find { |record| record.fetch("contract_id") == "codex.pre-tool-use.command" }
  matcher_record = manifest.fetch("records").find { |record| record.fetch("contract_id") == "codex.pre.matcher" }
  record_failure("contract importer creates generic readiness fixture records", "command record missing", output) unless command
  record_failure("contract importer creates generic readiness fixture records", "matcher record missing", output) unless matcher_record
  if command
    record_failure("contract importer creates generic readiness fixture records", "command hash missing", output) if command.fetch("command_execution_contract_hash") == StrictModeFixtures::ZERO_HASH
    record_failure("contract importer creates generic readiness fixture records", "command compatibility mismatch", output) unless command.fetch("compatibility_range").fetch("mode") == "unknown-only"
  end
  if matcher_record
    record_failure("contract importer creates generic readiness fixture records", "matcher should use hash sentinels", output) unless matcher_record.fetch("payload_schema_hash") == StrictModeFixtures::ZERO_HASH && matcher_record.fetch("decision_contract_hash") == StrictModeFixtures::ZERO_HASH && matcher_record.fetch("command_execution_contract_hash") == StrictModeFixtures::ZERO_HASH
  end
end

expect_pass("contract importer creates decision-output fixture record") do |root|
  contract_id = "codex.pre-tool-use.block"
  metadata = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => "codex",
    "event" => "pre-tool-use",
    "logical_event" => "pre-tool-use",
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
  capture = root.join("capture/decision")
  capture.mkpath
  metadata_path = capture.join("provider-output.json")
  stdout_path = capture.join("stdout")
  stderr_path = capture.join("stderr")
  exit_code_path = capture.join("exit-code")
  metadata_path.write(JSON.pretty_generate(metadata) + "\n")
  stdout_path.write("{\"decision\":\"block\",\"reason\":\"blocked\"}\n")
  stderr_path.write("")
  exit_code_path.write("0\n")

  status, output = run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "pre-tool-use",
    "--contract-kind", "decision-output",
    "--contract-id", contract_id,
    "--metadata", metadata_path,
    "--stdout", stdout_path,
    "--stderr", stderr_path,
    "--exit-code", exit_code_path,
    "--captured-at", "2026-05-06T00:00:00Z"
  )
  assert_no_stacktrace("contract importer creates decision-output fixture record", output)
  unless status.zero?
    record_failure("contract importer creates decision-output fixture record", "decision-output import failed", output)
    next
  end

  record = read_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records").fetch(0)
  record_failure("contract importer creates decision-output fixture record", "wrong contract kind", output) unless record.fetch("contract_kind") == "decision-output"
  record_failure("contract importer creates decision-output fixture record", "decision hash mismatch", output) unless record.fetch("decision_contract_hash") == metadata.fetch("decision_contract_hash")
  expected_paths = [
    "providers/codex/fixtures/decision-output/pre-tool-use/codex.pre-tool-use.block.exit-code",
    "providers/codex/fixtures/decision-output/pre-tool-use/codex.pre-tool-use.block.provider-output.json",
    "providers/codex/fixtures/decision-output/pre-tool-use/codex.pre-tool-use.block.stderr",
    "providers/codex/fixtures/decision-output/pre-tool-use/codex.pre-tool-use.block.stdout"
  ]
  record_failure("contract importer creates decision-output fixture record", "decision fixture role paths mismatch", output) unless record.fetch("fixture_file_hashes").map { |item| item.fetch("path") } == expected_paths
end

expect_pass("raw capture importer promotes captured payload fixtures") do |root|
  payload = "{\"event\":\"pre-tool-use\",\"thread_id\":\"t1\",\"tool_name\":\"apply_patch\",\"tool_input\":{\"patch\":\"*** Begin Patch\\n*** Add File: lib/raw_capture.rb\\n+puts 1\\n*** End Patch\\n\"}}\n"
  capture_root = root.join("state/discovery/raw")
  raw_dir = capture_root.join("codex/pre-tool-use")
  raw_dir.mkpath
  raw_path = raw_dir.join("20260507T000000-1-raw.payload")
  raw_path.write(payload)
  project = root.join("project")
  cwd = project.join("src")
  cwd.mkpath

  status, output = run_cmd(
    RAW_CAPTURE_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "pre-tool-use",
    "--capture-root", capture_root,
    "--cwd", cwd,
    "--project-dir", project,
    "--captured-at", "2026-05-07T00:00:00Z"
  )
  assert_no_stacktrace("raw capture importer promotes captured payload fixtures", output)
  unless status.zero?
    record_failure("raw capture importer promotes captured payload fixtures", "raw capture import failed", output)
    next
  end

  payload_hash = Digest::SHA256.hexdigest(payload)
  record = read_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records").fetch(0)
  record_failure("raw capture importer promotes captured payload fixtures", "wrong contract id", output) unless record.fetch("contract_id") == "codex.pre-tool-use.payload.#{payload_hash[0, 12]}"
  record_failure("raw capture importer promotes captured payload fixtures", "wrong contract kind", output) unless record.fetch("contract_kind") == "payload-schema"
  raw_fixture = record.fetch("fixture_file_hashes").find { |item| item.fetch("path").include?("/payloads/") }
  record_failure("raw capture importer promotes captured payload fixtures", "raw fixture missing", output) unless raw_fixture && root.join(raw_fixture.fetch("path")).binread == payload
end

expect_fail("payload-schema without normalized provider proof is rejected", "payload-schema must include exactly one normalized event fixture") do |root|
  path = fixture_file(root, "claude", "payloads/stop/only-raw.json", "{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\"}\n")
  record = record_for(root, provider: "claude", contract_id: "claude.stop.payload", contract_kind: "payload-schema", event: "stop", fixture_paths: [path])
  write_manifest(root, "claude", [record])
end

with_root do |root|
  name = "validator rejects payload-schema hash drift"
  exitstatus, output, _source = import_codex_payload_fixture(root, name)
  assert_no_stacktrace("#{name} setup", output)
  if exitstatus.zero?
    manifest_path = StrictModeFixtures.manifest_path(root, "codex")
    manifest = read_json(manifest_path)
    manifest["records"][0]["payload_schema_hash"] = Digest::SHA256.hexdigest("wrong")
    manifest["records"][0]["fixture_record_hash"] = StrictModeFixtures.hash_record(manifest["records"][0], "fixture_record_hash")
    manifest["manifest_hash"] = StrictModeFixtures.hash_record(manifest, "manifest_hash")
    write_raw_manifest(root, "codex", manifest)
    validate_status, validate_output = run_cmd(VALIDATOR, "--root", root)
    assert_no_stacktrace(name, validate_output)
    record_failure(name, "expected exit 1, got #{validate_status}", validate_output) unless validate_status == 1
    record_failure(name, "missing payload-schema hash diagnostic", validate_output) unless validate_output.include?("payload_schema_hash must bind raw shape, normalized event, and provider proof")
  else
    record_failure(name, "setup import failed", output)
  end
end

with_root do |root|
  name = "validator rejects payload-schema provider proof mismatch"
  exitstatus, output, source = import_codex_payload_fixture(root, name)
  assert_no_stacktrace("#{name} setup", output)
  if exitstatus.zero?
    manifest_path = StrictModeFixtures.manifest_path(root, "codex")
    manifest = read_json(manifest_path)
    record = manifest.fetch("records").fetch(0)
    proof_entry = record.fetch("fixture_file_hashes").find { |item| item.fetch("path").include?("/provider-proof/") }
    proof_path = root.join(proof_entry.fetch("path"))
    raw_payload = JSON.parse(source.read)
    mismatched_proof = StrictModeProviderDetection.proof(
      raw_payload,
      provider_arg: "claude",
      provider_arg_source: "fixture-import",
      payload_sha256: Digest::SHA256.file(source).hexdigest
    )
    proof_path.write(JSON.pretty_generate(mismatched_proof) + "\n")
    proof_entry["content_sha256"] = Digest::SHA256.file(proof_path).hexdigest
    record["payload_schema_hash"] = StrictModeFixtures.payload_schema_hash(record.fetch("provider"), record.fetch("event"), raw_payload, read_json(root.join(record.fetch("fixture_file_hashes").find { |item| item.fetch("path").include?("/normalized/") }.fetch("path"))), mismatched_proof)
    record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
    manifest["manifest_hash"] = StrictModeFixtures.hash_record(manifest, "manifest_hash")
    write_raw_manifest(root, "codex", manifest)
    validate_status, validate_output = run_cmd(VALIDATOR, "--root", root)
    assert_no_stacktrace(name, validate_output)
    record_failure(name, "expected exit 1, got #{validate_status}", validate_output) unless validate_status == 1
    record_failure(name, "missing provider proof match diagnostic", validate_output) unless validate_output.include?("provider_proof decision must be match")
  else
    record_failure(name, "setup import failed", output)
  end
end

expect_pass("importer records unknown provider version as unknown-only") do |root|
  source = root.join("capture/stop.json")
  source.dirname.mkpath
  source.write("{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"transcript_path\":\"/home/user/.claude/projects/session.jsonl\"}\n")
  exitstatus, output = run_cmd(IMPORTER, "--root", root, "--provider", "claude", "--event", "stop", "--source", source, "--captured-at", "2026-05-06T00:00:00Z")
  assert_no_stacktrace("importer records unknown provider version as unknown-only", output)
  unless exitstatus.zero?
    record_failure("importer records unknown provider version as unknown-only", "importer failed", output)
    next
  end
  record = read_json(StrictModeFixtures.manifest_path(root, "claude")).fetch("records").fetch(0)
  record_failure("importer records unknown provider version as unknown-only", "wrong provider version", output) unless record.fetch("provider_version") == "unknown"
  record_failure("importer records unknown provider version as unknown-only", "wrong compatibility mode", output) unless record.fetch("compatibility_range").fetch("mode") == "unknown-only"
end

expect_import_fail("importer rejects duplicate JSON keys", "duplicate-key-safe JSON") do |root|
  source = root.join("capture/stop.json")
  source.dirname.mkpath
  source.write("{\"event\":\"stop\",\"event\":\"again\"}\n")
  run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--source", source)
end

expect_import_fail("importer rejects symlink sources", "source path must not be a symlink") do |root|
  target = root.join("capture/real-stop.json")
  target.dirname.mkpath
  target.write("{\"event\":\"stop\"}\n")
  link = root.join("capture/linked-stop.json")
  File.symlink(target, link)
  run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--source", link)
end

expect_import_fail("importer rejects unsafe fixture destination", "fixture destination is not a safe provider fixture path") do |root|
  source = root.join("capture/stop.json")
  source.dirname.mkpath
  source.write("{\"event\":\"stop\"}\n")
  run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--source", source, "--fixture-name", "../outside.json")
end

expect_import_fail("contract importer rejects payload-schema kind", "payload-schema must use import-discovery-fixture.rb") do |root|
  source = root.join("capture/proof.txt")
  source.dirname.mkpath
  source.write("payload proof must go through the payload importer\n")
  run_cmd(CONTRACT_IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--contract-kind", "payload-schema", "--source", source)
end

expect_import_fail("contract importer rejects untyped command-execution proof", "malformed typed contract proof JSON") do |root|
  source = root.join("capture/command-proof.txt")
  source.dirname.mkpath
  source.write("not a command execution proof\n")
  run_cmd(CONTRACT_IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--contract-kind", "command-execution", "--contract-id", "codex.stop.command", "--source", source)
end

expect_import_fail("contract importer rejects self-attested command proof without discovery binding", "command-execution proofs require exactly one --discovery-record") do |root|
  source = root.join("capture/command-proof.json")
  source.dirname.mkpath
  source.write(JSON.pretty_generate(typed_contract_proof(provider: "codex", contract_kind: "command-execution", event: "stop", contract_id: "codex.stop.command", provider_version: "0.128.0", provider_build_hash: "b" * 64)) + "\n")
  run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "stop",
    "--contract-kind", "command-execution",
    "--contract-id", "codex.stop.command",
    "--source", source,
    "--provider-version", "0.128.0",
    "--provider-build-hash", "b" * 64
  )
end

with_root do |root|
  name = "contract importer rejects command discovery drift before fixture copy"
  _raw, payload_hash, provider_proof_hash = raw_payload_fixture(root, "codex", "stop")
  proof = bound_typed_proof(provider: "codex", contract_kind: "command-execution", event: "stop", contract_id: "codex.stop.command", payload_hash: payload_hash, provider_version: "0.128.0", provider_build_hash: "b" * 64)
  source = root.join("capture/command-proof.json")
  discovery = root.join("capture/command-discovery.json")
  stdout = root.join("capture/command.stdout")
  stderr = root.join("capture/command.stderr")
  exit_code = root.join("capture/command.exit-code")
  source.dirname.mkpath
  source.write(JSON.pretty_generate(proof) + "\n")
  drifted_discovery = discovery_record_for(proof, "stop", provider_proof_hash: provider_proof_hash)
  drifted_discovery["payload_sha256"] = "a" * 64
  discovery.write(JSON.pretty_generate(drifted_discovery) + "\n")
  stdout.write("")
  stderr.write("")
  exit_code.write("0\n")

  exitstatus, output = run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "stop",
    "--contract-kind", "command-execution",
    "--contract-id", "codex.stop.command",
    "--source", source,
    "--discovery-record", discovery,
    "--stdout", stdout,
    "--stderr", stderr,
    "--exit-code", exit_code,
    "--provider-version", "0.128.0",
    "--provider-build-hash", "b" * 64
  )
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
  record_failure(name, "missing discovery drift diagnostic", output) unless output.include?("discovery_record payload_sha256 must match proof")
  manifest = read_json(StrictModeFixtures.manifest_path(root, "codex"))
  record_failure(name, "failed command import updated manifest", output) unless manifest.fetch("records").empty?
  imported_files = Dir[root.join("providers/codex/fixtures/**/*")].reject do |path|
    File.directory?(path) || File.basename(path) == "fixture-manifest.json" || path.include?("/payloads/") || path.include?("/provider-proof/")
  end
  record_failure(name, "failed command import left typed fixture files", imported_files.join("\n")) unless imported_files.empty?
end

with_root do |root|
  name = "contract importer preflights all command fixture destinations before copy"
  _raw, payload_hash, provider_proof_hash = raw_payload_fixture(root, "codex", "stop")
  proof = bound_typed_proof(provider: "codex", contract_kind: "command-execution", event: "stop", contract_id: "codex.stop.command", payload_hash: payload_hash, provider_version: "0.128.0", provider_build_hash: "b" * 64)
  source = root.join("capture/command-proof.json")
  discovery = root.join("capture/command-discovery.json")
  stdout = root.join("capture/command.stdout")
  stderr = root.join("capture/command.stderr")
  exit_code = root.join("capture/command.exit-code")
  source.dirname.mkpath
  source.write(JSON.pretty_generate(proof) + "\n")
  discovery.write(JSON.pretty_generate(discovery_record_for(proof, "stop", provider_proof_hash: provider_proof_hash)) + "\n")
  stdout.write("")
  stderr.write("")
  exit_code.write("0\n")
  fixture_file(root, "codex", "command-execution/stop/codex.stop.command.discovery-record.json", "{\"different\":true}\n")

  exitstatus, output = run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "stop",
    "--contract-kind", "command-execution",
    "--contract-id", "codex.stop.command",
    "--source", source,
    "--discovery-record", discovery,
    "--stdout", stdout,
    "--stderr", stderr,
    "--exit-code", exit_code,
    "--provider-version", "0.128.0",
    "--provider-build-hash", "b" * 64
  )
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
  record_failure(name, "missing destination conflict diagnostic", output) unless output.include?("fixture destination already exists with different content")
  manifest = read_json(StrictModeFixtures.manifest_path(root, "codex"))
  record_failure(name, "failed conflict import updated manifest", output) unless manifest.fetch("records").empty?
  proof_destination = root.join("providers/codex/fixtures/command-execution/stop/codex.stop.command.command-execution.json")
  record_failure(name, "failed conflict import copied proof before sidecar preflight", output) if proof_destination.exist?
end

expect_import_fail("contract importer rejects custom typed proof fixture name", "fixture-name must be") do |root|
  source = root.join("capture/command-proof.json")
  source.dirname.mkpath
  source.write(JSON.pretty_generate(typed_contract_proof(provider: "codex", contract_kind: "command-execution", event: "stop", contract_id: "codex.stop.command", provider_version: "unknown")) + "\n")
  run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", "stop",
    "--contract-kind", "command-execution",
    "--contract-id", "codex.stop.command",
    "--source", source,
    "--fixture-name", "command-execution/stop/custom.json"
  )
end

expect_fail("validator rejects untyped command-execution fixture proof", "must be duplicate-key-safe JSON") do |root|
  path = fixture_file(root, "codex", "command-execution/stop/codex.stop.command.command-execution.json", "not a command execution proof\n")
  hashes = [fixture_hash_entry(root, path)]
  record = {
    "schema_version" => 1,
    "contract_id" => "codex.stop.command",
    "provider" => "codex",
    "provider_version" => "1.0.0",
    "provider_build_hash" => "",
    "platform" => RUBY_PLATFORM,
    "event" => "stop",
    "contract_kind" => "command-execution",
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "command_execution_contract_hash" => Digest::SHA256.hexdigest(JSON.generate(hashes)),
    "fixture_file_hashes" => hashes,
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
  write_manifest(root, "codex", [record])
end

expect_fail("validator rejects self-attested command proof without discovery binding", "must include exactly one external discovery record fixture") do |root|
  path = typed_fixture_file(root, provider: "codex", contract_kind: "command-execution", event: "stop", contract_id: "codex.stop.command", provider_version: "0.128.0", provider_build_hash: "b" * 64)
  record = record_for(root, provider: "codex", contract_id: "codex.stop.command", contract_kind: "command-execution", event: "stop", fixture_paths: [path], provider_version: "0.128.0")
  record["provider_build_hash"] = "b" * 64
  record["compatibility_range"]["provider_build_hashes"] = ["b" * 64]
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "codex", [record])
end

expect_fail("validator rejects event-order proof without early event before pre-tool-use", "must place fixture event before pre-tool-use") do |root|
  contract_id = "codex.session-start.order"
  path = typed_fixture_file(root, provider: "codex", contract_kind: "event-order", event: "session-start", contract_id: contract_id)
  proof = JSON.parse(path.read)
  proof["observed_order"].reverse!
  path.write(JSON.pretty_generate(proof) + "\n")
  record = record_for(root, provider: "codex", contract_id: contract_id, contract_kind: "event-order", event: "session-start", fixture_paths: [path])
  write_manifest(root, "codex", [record])
end

expect_import_fail("importer rejects duplicate contract without replace", "contract already exists") do |root|
  source = root.join("capture/stop.json")
  source.dirname.mkpath
  source.write("{\"event\":\"stop\"}\n")
  exitstatus, output = run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--source", source, "--captured-at", "2026-05-06T00:00:00Z")
  assert_no_stacktrace("importer rejects duplicate contract without replace setup", output)
  unless exitstatus.zero?
    record_failure("importer rejects duplicate contract without replace setup", "initial import failed", output)
    next [exitstatus, output]
  end
  run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "stop", "--source", source)
end

with_root do |root|
  name = "importer rejects logical event mismatch before manifest update"
  source = root.join("capture/mismatch.json")
  source.dirname.mkpath
  source.write("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\"}\n")
  exitstatus, output = run_cmd(IMPORTER, "--root", root, "--provider", "claude", "--event", "stop", "--source", source)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
  record_failure(name, "missing mismatch diagnostic", output) unless output.include?("logical event mismatch")
  manifest = read_json(StrictModeFixtures.manifest_path(root, "claude"))
  record_failure(name, "mismatch import updated manifest", output) unless manifest.fetch("records").empty?
  imported_files = Dir[root.join("providers/claude/fixtures/**/*")].reject { |path| File.directory?(path) || File.basename(path) == "fixture-manifest.json" }
  record_failure(name, "mismatch import left fixture files", imported_files.join("\n")) unless imported_files.empty?
end

with_root do |root|
  name = "importer rejects provider mismatch before manifest update"
  source = root.join("capture/provider-mismatch.json")
  source.dirname.mkpath
  source.write("{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\"}\n")
  exitstatus, output = run_cmd(IMPORTER, "--root", root, "--provider", "codex", "--event", "pre-tool-use", "--source", source)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
  record_failure(name, "missing provider mismatch diagnostic", output) unless output.include?("provider detection mismatch")
  manifest = read_json(StrictModeFixtures.manifest_path(root, "codex"))
  record_failure(name, "provider mismatch import updated manifest", output) unless manifest.fetch("records").empty?
  imported_files = Dir[root.join("providers/codex/fixtures/**/*")].reject { |path| File.directory?(path) || File.basename(path) == "fixture-manifest.json" }
  record_failure(name, "provider mismatch import left fixture files", imported_files.join("\n")) unless imported_files.empty?
end

expect_fail("fixture record exact schema is rejected", "fields must be exact") do |root|
  path = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  record["extra_field"] = "not allowed"
  write_manifest(root, "claude", [record])
end

expect_fail("fixture file hash drift is rejected", "content_sha256 mismatch") do |root|
  path = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  write_manifest(root, "claude", [record])
  path.write(JSON.pretty_generate(typed_contract_proof(provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher").merge("matcher" => "^changed$")) + "\n")
end

expect_fail("fixture record hash drift is rejected", "fixture_record_hash mismatch") do |root|
  path = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  write_manifest(root, "claude", [record])
  manifest = read_json(StrictModeFixtures.manifest_path(root, "claude"))
  manifest["records"][0]["event"] = "changed"
  manifest["manifest_hash"] = StrictModeFixtures.hash_record(manifest, "manifest_hash")
  write_raw_manifest(root, "claude", manifest)
end

expect_fail("duplicate contract ids are rejected", "contract_id values must be unique") do |root|
  path = typed_fixture_file(root, provider: "codex", contract_kind: "matcher", event: "stop", contract_id: "codex.stop.matcher")
  first = record_for(root, provider: "codex", contract_id: "codex.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  second = record_for(root, provider: "codex", contract_id: "codex.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  write_manifest(root, "codex", [first, second])
end

expect_fail("hash sentinel coupling is rejected", "decision_contract_hash must be zero sentinel") do |root|
  path = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "pre-tool-use", contract_id: "claude.matcher")
  record = record_for(root, provider: "claude", contract_id: "claude.matcher", contract_kind: "matcher", event: "pre-tool-use", fixture_paths: [path])
  record["decision_contract_hash"] = Digest::SHA256.hexdigest("bad")
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "claude", [record])
end

expect_fail("fixture records must be file-backed", "fixture_file_hashes must not be empty") do |root|
  record = record_for(root, provider: "claude", contract_id: "claude.matcher", contract_kind: "matcher", event: "pre-tool-use", fixture_paths: [])
  write_manifest(root, "claude", [record])
end

expect_fail("unsafe fixture paths are rejected", "not a safe repository-relative path") do |root|
  path = typed_fixture_file(root, provider: "codex", contract_kind: "matcher", event: "stop", contract_id: "codex.stop.matcher")
  record = record_for(root, provider: "codex", contract_id: "codex.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  record["fixture_file_hashes"][0]["path"] = "../outside.json"
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  write_manifest(root, "codex", [record])
end

expect_fail("cross-provider fixture paths are rejected", "not a safe repository-relative path") do |root|
  path = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")
  record = record_for(root, provider: "codex", contract_id: "codex.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path])
  write_manifest(root, "codex", [record])
end

expect_fail("symlink fixture files are rejected", "existing non-symlink fixture file") do |root|
  target = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")
  link = root.join("providers/claude/fixtures/matcher/linked-stop.json")
  File.symlink(target, link)
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [link])
  write_manifest(root, "claude", [record])
end

expect_fail("symlink fixture directories are rejected", "not a safe repository-relative path") do |root|
  outside = root.join("outside-fixtures")
  outside.mkpath
  outside.join("stop.json").write(JSON.pretty_generate(typed_contract_proof(provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")) + "\n")
  link_dir = root.join("providers/claude/fixtures/matcher")
  File.symlink(outside, link_dir)
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [link_dir.join("stop.json")])
  write_manifest(root, "claude", [record])
end

expect_fail("unknown-only compatibility requires unknown provider", "unknown-only requires provider_version=unknown") do |root|
  path = typed_fixture_file(root, provider: "codex", contract_kind: "matcher", event: "stop", contract_id: "codex.stop.matcher")
  compatibility = {
    "mode" => "unknown-only",
    "min_version" => "unknown",
    "max_version" => "unknown",
    "version_comparator" => "",
    "provider_build_hashes" => []
  }
  record = record_for(root, provider: "codex", contract_id: "codex.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path], compatibility: compatibility)
  write_manifest(root, "codex", [record])
end

expect_fail("range compatibility requires comparator record", "must reference a version-comparator record") do |root|
  path = typed_fixture_file(root, provider: "claude", contract_kind: "matcher", event: "stop", contract_id: "claude.stop.matcher")
  compatibility = {
    "mode" => "range",
    "min_version" => "1.0.0",
    "max_version" => "1.2.0",
    "version_comparator" => "claude.version.compare",
    "provider_build_hashes" => []
  }
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: [path], compatibility: compatibility)
  write_manifest(root, "claude", [record])
end

expect_pass("range compatibility accepts comparator record") do |root|
  paths = bound_matcher_fixture_paths(root, provider: "claude", event: "stop", contract_id: "claude.stop.matcher")
  comparator_file = fixture_file(root, "claude", "comparators/version.txt", "semver comparator fixture\n")
  comparator = record_for(root, provider: "claude", contract_id: "claude.version.compare", contract_kind: "version-comparator", event: "provider-version", fixture_paths: [comparator_file])
  compatibility = {
    "mode" => "range",
    "min_version" => "1.0.0",
    "max_version" => "1.2.0",
    "version_comparator" => "claude.version.compare",
    "provider_build_hashes" => []
  }
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: paths, compatibility: compatibility)
  write_manifest(root, "claude", [comparator, record])
end

expect_fail("manifest hash drift is rejected", "manifest_hash mismatch") do |root|
  path = StrictModeFixtures.manifest_path(root, "claude")
  manifest = read_json(path)
  manifest["generated_at"] = "2026-05-06T01:00:00Z"
  path.write(JSON.pretty_generate(manifest) + "\n")
end

expect_pass("generator creates deterministic empty manifests") do |root|
  FileUtils.rm_f(StrictModeFixtures.manifest_path(root, "claude"))
  FileUtils.rm_f(StrictModeFixtures.manifest_path(root, "codex"))
  exitstatus, output = run_cmd(GENERATOR, "--root", root, "--provider", "all")
  assert_no_stacktrace("generator creates deterministic empty manifests", output)
  record_failure("generator creates deterministic empty manifests", "generator failed", output) unless exitstatus.zero?
end

expect_pass("generator rehashes existing fixture records before manifest") do |root|
  paths = bound_matcher_fixture_paths(root, provider: "claude", event: "stop", contract_id: "claude.stop.matcher")
  record = record_for(root, provider: "claude", contract_id: "claude.stop.matcher", contract_kind: "matcher", event: "stop", fixture_paths: paths)
  record["fixture_record_hash"] = StrictModeFixtures::ZERO_HASH
  manifest = {
    "schema_version" => 1,
    "generated_at" => "2026-05-06T00:00:00Z",
    "records" => [record],
    "manifest_hash" => StrictModeFixtures::ZERO_HASH
  }
  write_raw_manifest(root, "claude", manifest)
  exitstatus, output = run_cmd(GENERATOR, "--root", root, "--provider", "claude")
  assert_no_stacktrace("generator rehashes existing fixture records before manifest", output)
  record_failure("generator rehashes existing fixture records before manifest", "generator failed", output) unless exitstatus.zero?
end

if $failures.empty?
  puts "fixture tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
