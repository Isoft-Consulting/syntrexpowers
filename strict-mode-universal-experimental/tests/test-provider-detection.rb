#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/metadata_lib"

ROOT = StrictModeMetadata.project_root
VERIFY = ROOT.join("tools/verify-provider-payload.rb")

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
  [status.exitstatus, stdout, stderr, stdout + stderr]
end

def with_root
  $cases += 1
  Dir.mktmpdir("strict-provider-detect-") do |dir|
    yield Pathname.new(dir).realpath
  end
end

def write_payload(root, name, payload)
  path = root.join("#{name}.json")
  path.write(JSON.generate(payload) + "\n")
  path
end

def expect_match(name, provider, payload)
  with_root do |root|
    source = write_payload(root, name.gsub(/[^a-z0-9]+/i, "-"), payload)
    status, stdout, _stderr, output = run_cmd(VERIFY, "--provider", provider, "--source", source)
    assert_no_stacktrace(name, output)
    unless status.zero?
      record_failure(name, "expected match success, got #{status}", output)
      next
    end
    proof = JSON.parse(stdout)
    record_failure(name, "wrong decision", output) unless proof.fetch("decision") == "match"
    record_failure(name, "wrong detected provider", output) unless proof.fetch("detected_provider") == provider
    record_failure(name, "wrong payload hash", output) unless proof.fetch("payload_sha256") == Digest::SHA256.file(source).hexdigest
    proof_path = root.join("proof.json")
    proof_path.write(JSON.pretty_generate(proof) + "\n")
    validate_status, _validate_stdout, _validate_stderr, validate_output = run_cmd(VERIFY, "--validate-proof", proof_path)
    assert_no_stacktrace("#{name} validate", validate_output)
    record_failure(name, "proof did not validate", validate_output) unless validate_status.zero?
  end
end

def expect_fail(name, provider, payload, expected)
  with_root do |root|
    source = write_payload(root, name.gsub(/[^a-z0-9]+/i, "-"), payload)
    status, _stdout, _stderr, output = run_cmd(VERIFY, "--provider", provider, "--source", source)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected failure, got #{status}", output) unless status == 1
    record_failure(name, "missing expected output #{expected.inspect}", output) unless output.include?(expected)
  end
end

expect_match("Claude indicators match Claude", "claude", {
  "hook_event_name" => "PreToolUse",
  "session_id" => "s1",
  "tool_name" => "Write"
})

expect_match("Codex indicators match Codex", "codex", {
  "event" => "pre-tool-use",
  "thread_id" => "t1",
  "tool_name" => "apply_patch"
})

expect_fail("Claude indicators reject Codex provider", "codex", {
  "hook_event_name" => "Stop",
  "tool_name" => "Bash"
}, "provider codex mismatches detected claude")

expect_fail("Conflicting indicators reject provider", "codex", {
  "hook_event_name" => "PreToolUse",
  "thread_id" => "t1",
  "tool_name" => "Write"
}, "conflicting provider indicators")

expect_fail("Unknown indicators reject fixture proof", "claude", {
  "message" => "no provider fields"
}, "could not be proven")

with_root do |root|
  name = "duplicate JSON keys are controlled failure"
  source = root.join("duplicate.json")
  source.write("{\"event\":\"stop\",\"event\":\"again\"}\n")
  status, _stdout, _stderr, output = run_cmd(VERIFY, "--provider", "codex", "--source", source)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected failure, got #{status}", output) unless status == 1
  record_failure(name, "missing duplicate-key diagnostic", output) unless output.include?("duplicate JSON object key")
end

with_root do |root|
  name = "proof hash drift is rejected"
  source = write_payload(root, "codex", {
    "event" => "stop",
    "thread_id" => "t1"
  })
  status, stdout, _stderr, output = run_cmd(VERIFY, "--provider", "codex", "--source", source)
  assert_no_stacktrace(name, output)
  if status.zero?
    proof = JSON.parse(stdout)
    proof["detected_provider"] = "claude"
    proof_path = root.join("tampered-proof.json")
    proof_path.write(JSON.pretty_generate(proof) + "\n")
    validate_status, _validate_stdout, _validate_stderr, validate_output = run_cmd(VERIFY, "--validate-proof", proof_path)
    assert_no_stacktrace(name, validate_output)
    record_failure(name, "expected proof validation failure, got #{validate_status}", validate_output) unless validate_status == 1
    record_failure(name, "missing proof hash diagnostic", validate_output) unless validate_output.include?("provider_proof_hash mismatch")
  else
    record_failure(name, "setup verification failed", output)
  end
end

with_root do |root|
  name = "proof extra fields are rejected"
  proof_path = root.join("proof-extra.json")
  proof_path.write(JSON.pretty_generate({
    "schema_version" => 1,
    "provider_arg" => "codex",
    "provider_arg_source" => "argv",
    "payload_sha256" => "0" * 64,
    "detected_provider" => "unknown",
    "decision" => "unknown",
    "claude_indicators" => [],
    "codex_indicators" => [],
    "conflict_indicators" => [],
    "fixture_usable" => false,
    "enforcement_usable" => false,
    "diagnostic" => "x",
    "provider_proof_hash" => "0" * 64,
    "extra" => true
  }) + "\n")
  status, _stdout, _stderr, output = run_cmd(VERIFY, "--validate-proof", proof_path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing exact-field diagnostic", output) unless output.include?("provider proof fields must be exact")
end

if $failures.empty?
  puts "provider detection tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
