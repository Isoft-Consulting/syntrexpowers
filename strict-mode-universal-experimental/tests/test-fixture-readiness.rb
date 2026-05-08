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
REPORTER = ROOT.join("tools/report-enforcement-readiness.rb")
PLANNER = ROOT.join("tools/plan-fixture-capture.rb")
IMPORTER = ROOT.join("tools/import-discovery-fixture.rb")
CONTRACT_IMPORTER = ROOT.join("tools/import-contract-fixture.rb")

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

def raw_payload_hash_for(root, provider, event)
  event_dir = root.join("providers/#{provider}/fixtures/payloads/#{event}")
  if event_dir.directory?
    raw = event_dir.children.select { |path| path.file? && path.extname == ".json" }.sort.first
    return Digest::SHA256.file(raw).hexdigest if raw
  end
  body = JSON.generate({ "event" => event, "thread_id" => "t1" }) + "\n"
  hash = Digest::SHA256.hexdigest(body)
  fixture_file(root, provider, "payloads/#{event}/#{hash[0, 16]}.json", body)
  hash
end

def provider_proof_hash_for(root, provider, event, payload_hash)
  proof_dir = root.join("providers/#{provider}/fixtures/provider-proof/#{event}")
  if proof_dir.directory?
    proof_dir.children.sort.each do |path|
      next unless path.file? && path.basename.to_s.end_with?(".provider-detection.json")

      proof = JSON.parse(path.read)
      return proof.fetch("provider_proof_hash") if proof["payload_sha256"] == payload_hash && proof["decision"] == "match"
    end
  end
  proof = {
    "schema_version" => 1,
    "provider_arg" => provider,
    "provider_arg_source" => "fixture-import",
    "payload_sha256" => payload_hash,
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
  fixture_file(root, provider, "provider-proof/#{event}/#{payload_hash[0, 16]}.provider-detection.json", JSON.pretty_generate(proof) + "\n")
  proof.fetch("provider_proof_hash")
end

def bind_proof_to_raw_payload!(root, provider, proof)
  event = proof.fetch("event")
  hash = raw_payload_hash_for(root, provider, event)
  provider_proof_hash = provider_proof_hash_for(root, provider, event, hash)
  case proof.fetch("proof_kind")
  when "#{provider}.command-execution.observed", "#{provider}.matcher.observed"
    proof["payload_sha256"] = hash
    proof["raw_payload_path"] = "/captures/#{hash[0, 12]}.payload"
  when "#{provider}.event-order.observed"
    proof["observed_order"].each do |item|
      item["payload_sha256"] = raw_payload_hash_for(root, provider, item.fetch("event"))
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

def compatibility_for(provider_version, provider_build_hash)
  if provider_version == "unknown"
    {
      "mode" => "unknown-only",
      "min_version" => "unknown",
      "max_version" => "unknown",
      "version_comparator" => "",
      "provider_build_hashes" => []
    }
  else
    {
      "mode" => "exact",
      "min_version" => provider_version,
      "max_version" => provider_version,
      "version_comparator" => "",
      "provider_build_hashes" => provider_build_hash.empty? ? [] : [provider_build_hash]
    }
  end
end

def record_for(root, provider:, contract_id:, contract_kind:, event:, provider_action: "block", provider_version: "1.0.0", provider_build_hash: "")
  if contract_kind == "decision-output"
    return decision_output_record_for(root, provider: provider, contract_id: contract_id, event: event, provider_action: provider_action, provider_version: provider_version, provider_build_hash: provider_build_hash)
  end

  fixture_paths = if StrictModeFixtures.typed_generic_contract_kind?(contract_kind)
                    proof = typed_contract_proof(
                      provider: provider,
                      contract_kind: contract_kind,
                      event: event,
                      contract_id: contract_id,
                      provider_version: provider_version,
                      provider_build_hash: provider_build_hash
                    )
                    bind_proof_to_raw_payload!(root, provider, proof)
                    proof_path = fixture_file(root, provider, "#{contract_kind}/#{event}/#{contract_id}.#{contract_kind}.json", JSON.pretty_generate(proof) + "\n")
                    paths = [proof_path]
                    case contract_kind
                    when "command-execution"
                      provider_hash = provider_proof_hash_for(root, provider, event, proof.fetch("payload_sha256"))
                      discovery_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.discovery-record.json", JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_hash)) + "\n")
                      stdout_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.stdout", "")
                      stderr_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.stderr", "")
                      exit_path = fixture_file(root, provider, "command-execution/#{event}/#{contract_id}.exit-code", "#{proof.fetch("hook_exit_status")}\n")
                      paths.concat([discovery_path, stdout_path, stderr_path, exit_path])
                    when "matcher"
                      provider_hash = provider_proof_hash_for(root, provider, event, proof.fetch("payload_sha256"))
                      paths << fixture_file(root, provider, "matcher/#{event}/#{contract_id}.discovery-record.json", JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_hash)) + "\n")
                    when "event-order"
                      proof.fetch("observed_order").each_with_index do |item, index|
                        command_like = {
                          "provider" => provider,
                          "payload_sha256" => item.fetch("payload_sha256"),
                          "raw_payload_path" => "/captures/#{item.fetch("payload_sha256")[0, 12]}.payload",
                          "raw_payload_captured" => true,
                          "hook_mode" => "discovery-log-only",
                          "provider_detection_decision" => "match",
                          "provider_proof_hash" => provider_proof_hash_for(root, provider, item.fetch("event"), item.fetch("payload_sha256")),
                          "discovery_recorded_at" => item.fetch("recorded_at")
                        }
                        paths << fixture_file(root, provider, "event-order/#{event}/#{contract_id}.#{index + 1}-#{item.fetch("event")}.discovery-record.json", JSON.pretty_generate(discovery_record_for(command_like, item.fetch("event"), provider_proof_hash: command_like.fetch("provider_proof_hash"))) + "\n")
                      end
                    end
                    paths
                  else
                    [fixture_file(root, provider, "#{contract_kind}/#{event}/#{contract_id}.txt", "#{contract_id}\n")]
                  end
  record = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => provider,
    "provider_version" => provider_version,
    "provider_build_hash" => provider_build_hash,
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => contract_kind,
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => fixture_paths.map { |fixture| fixture_hash_entry(root, fixture) }.sort_by { |item| item.fetch("path") },
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => compatibility_for(provider_version, provider_build_hash),
    "fixture_record_hash" => ""
  }
  surface_hash = Digest::SHA256.hexdigest(JSON.generate(record.fetch("fixture_file_hashes")))
  case contract_kind
  when "command-execution"
    proof = StrictModeFixtures.load_typed_contract_proof(fixture_paths.first)
    record["command_execution_contract_hash"] = StrictModeFixtures.typed_contract_proof_hash(record, proof)
  when "decision-output"
    record["decision_contract_hash"] = surface_hash
  when "worker-invocation"
    record["decision_contract_hash"] = surface_hash
    record["command_execution_contract_hash"] = surface_hash
  end
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def decision_output_record_for(root, provider:, contract_id:, event:, provider_action: "block", provider_version: "1.0.0", provider_build_hash: "")
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
    "provider_version" => provider_version,
    "provider_build_hash" => provider_build_hash,
    "platform" => RUBY_PLATFORM,
    "event" => event,
    "contract_kind" => "decision-output",
    "payload_schema_hash" => StrictModeFixtures::ZERO_HASH,
    "decision_contract_hash" => metadata.fetch("decision_contract_hash"),
    "command_execution_contract_hash" => StrictModeFixtures::ZERO_HASH,
    "fixture_file_hashes" => [metadata_path, stdout_path, stderr_path, exit_code_path].map { |path| fixture_hash_entry(root, path) }.sort_by { |item| item.fetch("path") },
    "captured_at" => "2026-05-06T00:00:00Z",
    "compatibility_range" => compatibility_for(provider_version, provider_build_hash),
    "fixture_record_hash" => ""
  }
  record["fixture_record_hash"] = StrictModeFixtures.hash_record(record, "fixture_record_hash")
  record
end

def unknown_only(record)
  copy = JSON.parse(JSON.generate(record))
  copy["provider_version"] = "unknown"
  copy["provider_build_hash"] = ""
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
  copy["provider_build_hash"] = ""
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

def import_codex_payload(root, event, provider_version: "unknown", provider_build_hash: "")
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
  args = [IMPORTER, "--root", root, "--provider", "codex", "--event", event, "--source", source, "--cwd", cwd, "--project-dir", project, "--captured-at", "2026-05-06T00:00:00Z", "--provider-version", provider_version]
  args.concat(["--provider-build-hash", provider_build_hash]) unless provider_build_hash.empty?
  run_cmd(*args)
end

def import_codex_contract(root, event, contract_kind, contract_id)
  source = root.join("capture/contracts/#{contract_kind}-#{event}.json")
  source.dirname.mkpath
  proof = typed_contract_proof(
    provider: "codex",
    contract_kind: contract_kind,
    event: event,
    contract_id: contract_id,
    provider_version: "unknown"
  )
  bind_proof_to_raw_payload!(root, "codex", proof)
  source.write(JSON.pretty_generate(proof) + "\n")
  args = [
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", event,
    "--contract-kind", contract_kind,
    "--contract-id", contract_id,
    "--source", source,
    "--captured-at", "2026-05-06T00:00:00Z"
  ]
  case contract_kind
  when "command-execution"
    discovery = root.join("capture/contracts/#{contract_kind}-#{event}.discovery.json")
    stdout = root.join("capture/contracts/#{contract_kind}-#{event}.stdout")
    stderr = root.join("capture/contracts/#{contract_kind}-#{event}.stderr")
    exit_code = root.join("capture/contracts/#{contract_kind}-#{event}.exit-code")
    provider_hash = provider_proof_hash_for(root, "codex", event, proof.fetch("payload_sha256"))
    discovery.write(JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_hash)) + "\n")
    stdout.write("")
    stderr.write("")
    exit_code.write("#{proof.fetch("hook_exit_status")}\n")
    args.concat(["--discovery-record", discovery, "--stdout", stdout, "--stderr", stderr, "--exit-code", exit_code])
  when "matcher"
    discovery = root.join("capture/contracts/#{contract_kind}-#{event}.discovery.json")
    provider_hash = provider_proof_hash_for(root, "codex", event, proof.fetch("payload_sha256"))
    discovery.write(JSON.pretty_generate(discovery_record_for(proof, event, provider_proof_hash: provider_hash)) + "\n")
    args.concat(["--discovery-record", discovery])
  when "event-order"
    proof.fetch("observed_order").each_with_index do |item, index|
      discovery = root.join("capture/contracts/#{contract_kind}-#{event}.#{index}.discovery.json")
      command_like = {
        "provider" => "codex",
        "payload_sha256" => item.fetch("payload_sha256"),
        "raw_payload_path" => "/captures/#{item.fetch("payload_sha256")[0, 12]}.payload",
        "raw_payload_captured" => true,
        "hook_mode" => "discovery-log-only",
        "provider_detection_decision" => "match",
        "provider_proof_hash" => provider_proof_hash_for(root, "codex", item.fetch("event"), item.fetch("payload_sha256")),
        "discovery_recorded_at" => item.fetch("recorded_at")
      }
      discovery.write(JSON.pretty_generate(discovery_record_for(command_like, item.fetch("event"), provider_proof_hash: command_like.fetch("provider_proof_hash"))) + "\n")
      args.concat(["--discovery-record", discovery])
    end
  end
  run_cmd(*args)
end

def import_codex_decision_output(root, event, contract_id)
  capture = root.join("capture/decision-output/#{event}")
  capture.mkpath
  metadata = {
    "schema_version" => 1,
    "contract_id" => contract_id,
    "provider" => "codex",
    "event" => event,
    "logical_event" => event,
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
  metadata_path = capture.join("#{event}.provider-output.json")
  stdout_path = capture.join("#{event}.stdout")
  stderr_path = capture.join("#{event}.stderr")
  exit_code_path = capture.join("#{event}.exit-code")
  metadata_path.write(JSON.pretty_generate(metadata) + "\n")
  stdout_path.write("{\"decision\":\"block\",\"reason\":\"blocked\"}\n")
  stderr_path.write("")
  exit_code_path.write("0\n")
  run_cmd(
    CONTRACT_IMPORTER,
    "--root", root,
    "--provider", "codex",
    "--event", event,
    "--contract-kind", "decision-output",
    "--contract-id", contract_id,
    "--metadata", metadata_path,
    "--stdout", stdout_path,
    "--stderr", stderr_path,
    "--exit-code", exit_code_path,
    "--captured-at", "2026-05-06T00:00:00Z"
  )
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
  name = "enforcing report summarizes missing required fixture proofs"
  report = StrictModeFixtureReadiness.enforcing_report(root, ["codex"])
  record_failure(name, "report should not be ready", report.inspect) if report.fetch("ready")
  provider = report.fetch("providers").first
  record_failure(name, "wrong provider", report.inspect) unless provider.fetch("provider") == "codex"
  record_failure(name, "manifest should be valid", report.inspect) unless provider.fetch("manifest_valid")
  record_failure(name, "expected zero enforceable records", report.inspect) unless provider.fetch("enforceable_record_count") == 0
  pre_check = provider.fetch("required_checks").find { |check| check.fetch("event") == "pre-tool-use" && check.fetch("contract_kind") == "matcher" }
  record_failure(name, "missing pre-tool matcher check", report.inspect) unless pre_check
  record_failure(name, "pre-tool matcher should be missing", report.inspect) if pre_check&.fetch("ready")
  record_failure(name, "missing top-level errors", report.inspect) unless report.fetch("errors").include?("missing codex stop decision-output fixture with block/continuation provider output")

  status, output = run_cmd(REPORTER, "--root", root, "--provider", "codex", "--format", "json")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected reporter exit 1, got #{status}", output) unless status == 1
  parsed = JSON.parse(output)
  record_failure(name, "json report mismatch", output) if parsed.fetch("report_kind") != "enforcing-readiness" || parsed.fetch("ready")
end

with_root do |root|
  name = "fixture capture planner emits importer checklist for missing proofs"
  status, output = run_cmd(PLANNER, "--root", root, "--provider", "codex", "--format", "json")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected planner exit 0, got #{status}", output) unless status.zero?
  parsed = JSON.parse(output)
  provider = parsed.fetch("providers").first
  missing_required = provider.fetch("missing_required")
  missing_optional = provider.fetch("missing_optional")
  record_failure(name, "wrong plan kind", output) unless parsed.fetch("plan_kind") == "fixture-capture"
  record_failure(name, "planner should report not ready", output) if parsed.fetch("ready")
  record_failure(name, "wrong required missing count", output) unless parsed.fetch("missing_required_count") == 14 && missing_required.length == 14
  record_failure(name, "wrong optional missing count", output) unless parsed.fetch("missing_optional_count") == 3 && missing_optional.length == 3
  early = missing_required.find { |step| step.fetch("event") == "early-baseline" && step.fetch("contract_kind") == "event-order" }
  payload = missing_required.find { |step| step.fetch("event") == "pre-tool-use" && step.fetch("contract_kind") == "payload-schema" }
  decision = missing_required.find { |step| step.fetch("event") == "stop" && step.fetch("contract_kind") == "decision-output" }
  record_failure(name, "missing early baseline step", output) unless early
  record_failure(name, "missing payload step", output) unless payload
  record_failure(name, "missing decision step", output) unless decision
  if early
    record_failure(name, "early accepted events mismatch", output) unless early.fetch("accepted_events") == %w[session-start user-prompt-submit]
    record_failure(name, "early command must use accepted event placeholder", output) unless early.fetch("example_command").include?("--event <session-start-or-user-prompt-submit>")
  end
  if payload
    record_failure(name, "payload importer mismatch", output) unless payload.fetch("importer") == "tools/import-discovery-fixture.rb"
    record_failure(name, "payload source input missing", output) unless payload.fetch("required_inputs").any? { |input| input.fetch("name") == "source_payload" }
  end
  if decision
    record_failure(name, "decision importer mismatch", output) unless decision.fetch("importer") == "tools/import-contract-fixture.rb"
    record_failure(name, "decision metadata input missing", output) unless decision.fetch("required_inputs").any? { |input| input.fetch("name") == "provider_output_metadata" }
    record_failure(name, "decision command missing captured output args", output) unless decision.fetch("example_command").include?("--metadata <provider-output.json>") && decision.fetch("example_command").include?("--exit-code <exit-code>")
  end

  status, output = run_cmd(PLANNER, "--root", root, "--provider", "codex")
  assert_no_stacktrace("#{name} text", output)
  record_failure(name, "expected text planner exit 0, got #{status}", output) unless status.zero?
  record_failure(name, "text planner missing decision step", output) unless output.include?("required stop decision-output -> tools/import-contract-fixture.rb")
end

with_root do |root|
  name = "enforcing report accepts exact provider version selectors"
  payload_records = []
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    status, output = import_codex_payload(root, event, provider_version: "1.0.0")
    assert_no_stacktrace("#{name} import #{event}", output)
    if status.zero?
      payload_records = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records")
    else
      record_failure(name, "payload import failed for #{event}", output)
    end
  end
  records = [
    record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start"),
    record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use")
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event)
  end
  %w[pre-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.decision", contract_kind: "decision-output", event: event)
  end
  write_manifest(root, "codex", payload_records + records)

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex")
  assert_no_stacktrace("#{name} checker unknown", output)
  record_failure(name, "expected checker exit 1 without exact provider version, got #{status}", output) unless status == 1
  record_failure(name, "missing version-gated readiness diagnostic", output) unless output.include?("missing codex stop decision-output fixture")

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0")
  assert_no_stacktrace("#{name} checker exact", output)
  record_failure(name, "expected checker exit 0 with exact provider version, got #{status}", output) unless status.zero?
  record_failure(name, "missing checker success diagnostic", output) unless output.include?("fixture readiness passed")

  status, output = run_cmd(REPORTER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0", "--format", "json")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected reporter exit 0, got #{status}", output) unless status.zero?
  parsed = JSON.parse(output)
  provider = parsed.fetch("providers").first
  record_failure(name, "report should be ready", output) unless parsed.fetch("ready") && provider.fetch("ready")
  record_failure(name, "provider version missing", output) unless provider.fetch("installed_version") == "1.0.0"
  record_failure(name, "selected output contracts missing", output) unless provider.fetch("selected_output_contracts").length == 2

  status, output = run_cmd(REPORTER, "--root", root, "--provider", "codex", "--provider-version", "claude=1.0.0")
  assert_no_stacktrace("#{name} invalid selector", output)
  record_failure(name, "expected invalid selector exit 2, got #{status}", output) unless status == 2
  record_failure(name, "missing invalid selector diagnostic", output) unless output.include?("outside --provider selection")

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex", "--provider-version", "claude=1.0.0")
  assert_no_stacktrace("#{name} checker invalid selector", output)
  record_failure(name, "expected checker invalid selector exit 2, got #{status}", output) unless status == 2
  record_failure(name, "missing checker invalid selector diagnostic", output) unless output.include?("outside --provider selection")
end

with_root do |root|
  name = "exact provider build hashes gate enforcing readiness"
  build_hash = "a" * 64
  wrong_build_hash = "b" * 64
  payload_records = []
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    status, output = import_codex_payload(root, event, provider_version: "1.0.0", provider_build_hash: build_hash)
    assert_no_stacktrace("#{name} payload #{event}", output)
    if status.zero?
      payload_records = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(root, "codex")).fetch("records")
    else
      record_failure(name, "payload import failed for #{event}", output)
    end
  end
  records = [
    record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start", provider_build_hash: build_hash),
    record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use", provider_build_hash: build_hash)
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event, provider_build_hash: build_hash)
  end
  %w[pre-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.decision", contract_kind: "decision-output", event: event, provider_build_hash: build_hash)
  end
  write_manifest(root, "codex", payload_records + records)

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0")
  assert_no_stacktrace("#{name} missing build", output)
  record_failure(name, "expected missing build hash exit 1, got #{status}", output) unless status == 1
  record_failure(name, "missing build-gated readiness diagnostic", output) unless output.include?("missing codex stop decision-output fixture")

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0", "--provider-build-hash", "codex=#{wrong_build_hash}")
  assert_no_stacktrace("#{name} wrong build", output)
  record_failure(name, "expected wrong build hash exit 1, got #{status}", output) unless status == 1
  record_failure(name, "missing wrong-build readiness diagnostic", output) unless output.include?("missing codex stop decision-output fixture")

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0", "--provider-build-hash", "codex=#{build_hash}")
  assert_no_stacktrace("#{name} matching build", output)
  record_failure(name, "expected matching build hash exit 0, got #{status}", output) unless status.zero?
  record_failure(name, "missing checker success diagnostic", output) unless output.include?("fixture readiness passed")

  status, output = run_cmd(REPORTER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0", "--provider-build-hash", "codex=#{build_hash}", "--format", "json")
  assert_no_stacktrace("#{name} reporter", output)
  record_failure(name, "expected reporter exit 0, got #{status}", output) unless status.zero?
  parsed = JSON.parse(output)
  provider = parsed.fetch("providers").first
  selected = provider.fetch("selected_output_contracts")
  record_failure(name, "report build hash missing", output) unless provider.fetch("installed_build_hash") == build_hash
  record_failure(name, "selected contracts did not preserve build hash", output) unless selected.length == 2 && selected.all? { |record| record.fetch("provider_build_hash") == build_hash }

  status, output = run_cmd(PLANNER, "--root", root, "--provider", "codex", "--provider-version", "codex=1.0.0", "--provider-build-hash", "codex=#{build_hash}", "--format", "json")
  assert_no_stacktrace("#{name} planner", output)
  record_failure(name, "expected planner exit 0, got #{status}", output) unless status.zero?
  parsed = JSON.parse(output)
  provider = parsed.fetch("providers").first
  optional_command = provider.fetch("missing_optional").first.fetch("example_command")
  record_failure(name, "planner required gaps should be empty", output) unless provider.fetch("missing_required").empty?
  record_failure(name, "planner command missing provider build hash", output) unless optional_command.include?("--provider-build-hash #{build_hash}")

  status, output = run_cmd(REPORTER, "--root", root, "--provider", "codex", "--provider-build-hash", "claude=#{build_hash}")
  assert_no_stacktrace("#{name} invalid selector", output)
  record_failure(name, "expected invalid build selector exit 2, got #{status}", output) unless status == 2
  record_failure(name, "missing invalid build selector diagnostic", output) unless output.include?("outside --provider selection")
end

with_root do |root|
  name = "importer CLI workflow can satisfy Codex enforcing readiness"
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    status, output = import_codex_payload(root, event)
    assert_no_stacktrace("#{name} payload #{event}", output)
    record_failure(name, "payload import failed for #{event}", output) unless status.zero?

    status, output = import_codex_contract(root, event, "command-execution", "codex.#{event}.command")
    assert_no_stacktrace("#{name} command #{event}", output)
    record_failure(name, "command import failed for #{event}", output) unless status.zero?
  end

  [
    ["session-start", "event-order", "codex.session-start.order"],
    ["pre-tool-use", "matcher", "codex.pre-tool-use.matcher"]
  ].each do |event, kind, contract_id|
    status, output = import_codex_contract(root, event, kind, contract_id)
    assert_no_stacktrace("#{name} #{kind}", output)
    record_failure(name, "#{kind} import failed", output) unless status.zero?
  end

  %w[pre-tool-use stop].each do |event|
    status, output = import_codex_decision_output(root, event, "codex.#{event}.block")
    assert_no_stacktrace("#{name} decision #{event}", output)
    record_failure(name, "decision-output import failed for #{event}", output) unless status.zero?
  end

  status, output = run_cmd(CHECKER, "--root", root, "--provider", "codex")
  assert_no_stacktrace("#{name} checker", output)
  record_failure(name, "expected checker exit 0, got #{status}", output) unless status.zero?
  record_failure(name, "missing checker success diagnostic", output) unless output.include?("fixture readiness passed")

  status, output = run_cmd(REPORTER, "--root", root, "--provider", "codex", "--format", "json")
  assert_no_stacktrace("#{name} reporter", output)
  record_failure(name, "expected reporter exit 0, got #{status}", output) unless status.zero?
  parsed = JSON.parse(output)
  provider = parsed.fetch("providers").first
  selected = provider.fetch("selected_output_contracts")
  record_failure(name, "report should be ready", output) unless parsed.fetch("ready") && provider.fetch("ready")
  record_failure(name, "selected output contract mismatch", output) unless selected.map { |record| [record.fetch("logical_event"), record.fetch("contract_id")] } == [["pre-tool-use", "codex.pre-tool-use.block"], ["stop", "codex.stop.block"]]

  status, output = run_cmd(PLANNER, "--root", root, "--provider", "codex", "--format", "json")
  assert_no_stacktrace("#{name} planner", output)
  record_failure(name, "expected planner exit 0, got #{status}", output) unless status.zero?
  parsed = JSON.parse(output)
  provider = parsed.fetch("providers").first
  record_failure(name, "planner should report ready", output) unless parsed.fetch("ready") && provider.fetch("ready")
  record_failure(name, "planner required gaps should be empty", output) unless provider.fetch("missing_required").empty?
  optional = provider.fetch("missing_optional").map { |step| [step.fetch("event"), step.fetch("contract_kind")] }
  expected_optional = [
    ["permission-request", "payload-schema"],
    ["permission-request", "command-execution"],
    ["permission-request", "decision-output"]
  ]
  record_failure(name, "planner optional gaps mismatch", output) unless optional == expected_optional
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
  build_exact = record_for(root, provider: "claude", contract_id: "claude.stop.build.command", contract_kind: "command-execution", event: "stop", provider_build_hash: "a" * 64)
  unknown = unknown_only(exact)
  range = range_compatible(exact)
  record_failure(name, "exact record should match known installed version") unless StrictModeFixtureReadiness.enforceable_record?(exact, "1.0.0")
  record_failure(name, "exact record should not match unknown installed version") if StrictModeFixtureReadiness.enforceable_record?(exact, "unknown")
  record_failure(name, "build-bound exact record should require build hash") if StrictModeFixtureReadiness.enforceable_record?(build_exact, "1.0.0")
  record_failure(name, "build-bound exact record should reject wrong build hash") if StrictModeFixtureReadiness.enforceable_record?(build_exact, "1.0.0", "b" * 64)
  record_failure(name, "build-bound exact record should match known build hash") unless StrictModeFixtureReadiness.enforceable_record?(build_exact, "1.0.0", "a" * 64)
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
    record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start", provider_version: "unknown"),
    record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use", provider_version: "unknown")
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event, provider_version: "unknown")
  end
  %w[pre-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.decision", contract_kind: "decision-output", event: event, provider_version: "unknown")
  end
  records << record_for(root, provider: "codex", contract_id: "codex.pre-tool-use.deny", contract_kind: "decision-output", event: "pre-tool-use", provider_action: "deny", provider_version: "unknown")
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

  report = StrictModeFixtureReadiness.enforcing_report(root, ["codex"])
  record_failure(name, "report should be ready", JSON.pretty_generate(report)) unless report.fetch("ready")
  provider = report.fetch("providers").first
  record_failure(name, "report selected output mismatch", provider.fetch("selected_output_contracts").inspect) unless provider.fetch("selected_output_contracts").map { |record| record.fetch("contract_id") } == ["codex.pre-tool-use.decision", "codex.stop.decision"]
  record_failure(name, "required checks should be ready", JSON.pretty_generate(report)) unless provider.fetch("required_checks").all? { |check| check.fetch("ready") }
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
  permission_command = record_for(root, provider: "codex", contract_id: "codex.permission-request.command", contract_kind: "command-execution", event: "permission-request", provider_version: "unknown")
  permission_decision = record_for(root, provider: "codex", contract_id: "codex.permission-request.deny", contract_kind: "decision-output", event: "permission-request", provider_action: "deny", provider_version: "unknown")
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
  permission = record_for(root, provider: "codex", contract_id: "codex.permission-request.deny", contract_kind: "decision-output", event: "permission-request", provider_action: "deny", provider_version: "unknown")
  write_manifest(root, "codex", [permission])

  selected = StrictModeFixtureReadiness.selected_output_contracts(root, ["codex"])
  record_failure(name, "permission decision-output was selected without payload/command proof", selected.inspect) if selected.any? { |record| record.fetch("event") == "permission-request" }
end

with_root do |root|
  name = "blocking events require event-specific decision-output fixtures"
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
    record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start", provider_version: "unknown"),
    record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use", provider_version: "unknown")
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event, provider_version: "unknown")
  end
  records << record_for(root, provider: "codex", contract_id: "codex.pre.warn", contract_kind: "decision-output", event: "pre-tool-use", provider_action: "warn", provider_version: "unknown")
  records << record_for(root, provider: "codex", contract_id: "codex.stop.block", contract_kind: "decision-output", event: "stop", provider_version: "unknown")
  write_manifest(root, "codex", payload_records + records)

  errors = StrictModeFixtureReadiness.enforcing_errors(root, ["codex"])
  expected = "missing codex pre-tool-use decision-output fixture with block/deny provider output"
  record_failure(name, "missing block/deny readiness diagnostic", errors.join("\n")) unless errors.include?(expected)
  record_failure(name, "stop block fixture should satisfy readiness", errors.join("\n")) if errors.any? { |error| error.include?("missing codex stop decision-output") }
end

with_root do |root|
  name = "stop readiness rejects deny-only decision-output fixtures"
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
    record_for(root, provider: "codex", contract_id: "codex.order", contract_kind: "event-order", event: "session-start", provider_version: "unknown"),
    record_for(root, provider: "codex", contract_id: "codex.pre.matcher", contract_kind: "matcher", event: "pre-tool-use", provider_version: "unknown"),
    record_for(root, provider: "codex", contract_id: "codex.pre.block", contract_kind: "decision-output", event: "pre-tool-use", provider_version: "unknown"),
    record_for(root, provider: "codex", contract_id: "codex.stop.deny", contract_kind: "decision-output", event: "stop", provider_action: "deny", provider_version: "unknown")
  ]
  %w[session-start user-prompt-submit pre-tool-use post-tool-use stop].each do |event|
    records << record_for(root, provider: "codex", contract_id: "codex.#{event}.command", contract_kind: "command-execution", event: event, provider_version: "unknown")
  end
  write_manifest(root, "codex", payload_records + records)

  errors = StrictModeFixtureReadiness.enforcing_errors(root, ["codex"])
  expected = "missing codex stop decision-output fixture with block/continuation provider output"
  record_failure(name, "missing stop continuation readiness diagnostic", errors.join("\n")) unless errors.include?(expected)
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

$cases += 1
begin
  name = "readme codex exact fixture selectors match checked-in manifest"
  readme = ROOT.join("README.md").read
  manifest = StrictModeFixtures.load_json(StrictModeFixtures.manifest_path(ROOT, "codex"))
  versions = manifest.fetch("records").map { |record| record.fetch("provider_version") }.uniq.sort
  build_hashes = manifest.fetch("records").map { |record| record.fetch("provider_build_hash") }.reject(&:empty?).uniq.sort
  unless versions.size == 1 && build_hashes.size == 1
    record_failure(name, "expected one checked-in Codex version/build hash", { "versions" => versions, "build_hashes" => build_hashes }.inspect)
  else
    version = versions.fetch(0)
    build_hash = build_hashes.fetch(0)
    record_failure(name, "README missing checked-in provider version #{version}") unless readme.include?("--provider-version codex=#{version}")
    record_failure(name, "README missing checked-in provider build hash #{build_hash}") unless readme.include?("--provider-build-hash codex=#{build_hash}")
    record_failure(name, "README still documents stale codex=1.0.0 selector") if version != "1.0.0" && readme.include?("--provider-version codex=1.0.0")
  end
rescue StandardError => e
  record_failure("readme codex exact fixture selectors match checked-in manifest", e.message)
end

if $failures.empty?
  puts "fixture readiness tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
