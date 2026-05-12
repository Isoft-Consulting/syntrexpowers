#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "rbconfig"
require_relative "../tools/metadata_lib"

ROOT = Pathname.new(__dir__).parent.expand_path
JUDGE = ROOT.join("bin/strict-judge")
ZERO_HASH = "0" * 64
EXPECTED_KEYS = %w[
  backend
  confidence
  findings
  model
  reason
  response_hash
  reviewed_artifact_hash
  reviewed_scope_digest
  schema_version
  verdict
].freeze

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def run_judge(*args)
  Open3.capture3(RbConfig.ruby, JUDGE.to_s, *args)
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def parse_json(name, stdout)
  JSON.parse(stdout)
rescue JSON::ParserError => e
  record_failure(name, "response is not valid JSON: #{e.message}", stdout)
  {}
end

def assert_unknown_response(name, record, backend:, model:, reviewed_scope_digest: ZERO_HASH, reviewed_artifact_hash: ZERO_HASH)
  assert(name, record.keys.sort == EXPECTED_KEYS, "response fields drifted: #{record.keys.sort.inspect}", JSON.pretty_generate(record))
  assert(name, record.fetch("schema_version") == 1, "schema_version mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("verdict") == "unknown", "verdict mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("reason") == "judge-invocation-unverified", "reason mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("findings") == [], "findings must be empty for unknown", JSON.pretty_generate(record))
  assert(name, record.fetch("reviewed_scope_digest") == reviewed_scope_digest, "scope digest mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("reviewed_artifact_hash") == reviewed_artifact_hash, "artifact hash mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("confidence") == "0.000", "confidence must be canonical", JSON.pretty_generate(record))
  assert(name, record.fetch("backend") == backend, "backend mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("model") == model, "model mismatch", JSON.pretty_generate(record))
  assert(name, record.fetch("response_hash") == StrictModeMetadata.hash_record(record, "response_hash"), "response_hash mismatch", JSON.pretty_generate(record))
end

def assert_canonical_stdout(name, stdout, record)
  assert(name, stdout == "#{StrictModeMetadata.canonical_json(record)}\n", "stdout must be canonical JSON", stdout)
end

$cases += 1
name = "codex fixture-gated judge response is schema-shaped unknown"
scope_hash = "1" * 64
artifact_hash = "2" * 64
stdout, stderr, status = run_judge("--provider", "codex", "--reviewed-scope-digest", scope_hash, "--reviewed-artifact-hash", artifact_hash)
assert(name, status.exitstatus == 0, "expected successful fixture-gated response, got #{status.exitstatus}", stdout + stderr)
record = parse_json(name, stdout)
unless record.empty?
  assert_unknown_response(name, record, backend: "codex", model: "gpt-5.3-codex-spark", reviewed_scope_digest: scope_hash, reviewed_artifact_hash: artifact_hash)
  assert_canonical_stdout(name, stdout, record)
end
assert(name, stderr.empty?, "expected no stderr", stderr)

$cases += 1
name = "claude fixture-gated judge response binds backend and model"
stdout, stderr, status = run_judge("--provider", "claude")
assert(name, status.exitstatus == 0, "expected successful fixture-gated response, got #{status.exitstatus}", stdout + stderr)
record = parse_json(name, stdout)
unless record.empty?
  assert_unknown_response(name, record, backend: "claude", model: "claude-haiku-4-5-20251001")
  assert_canonical_stdout(name, stdout, record)
end
assert(name, stderr.empty?, "expected no stderr", stderr)

$cases += 1
name = "claude fixture-gated judge response binds reviewed scope and artifact hashes"
claude_scope_hash = "3" * 64
claude_artifact_hash = "4" * 64
stdout, stderr, status = run_judge("--provider", "claude", "--reviewed-scope-digest", claude_scope_hash, "--reviewed-artifact-hash", claude_artifact_hash)
assert(name, status.exitstatus == 0, "expected successful fixture-gated response, got #{status.exitstatus}", stdout + stderr)
record = parse_json(name, stdout)
unless record.empty?
  assert_unknown_response(name, record, backend: "claude", model: "claude-haiku-4-5-20251001", reviewed_scope_digest: claude_scope_hash, reviewed_artifact_hash: claude_artifact_hash)
  assert_canonical_stdout(name, stdout, record)
end
assert(name, stderr.empty?, "expected no stderr", stderr)

$cases += 1
name = "invalid reviewed hash exits as usage error for claude"
stdout, stderr, status = run_judge("--provider", "claude", "--reviewed-scope-digest", "ABC")
assert(name, status.exitstatus == 2, "expected usage failure, got #{status.exitstatus}", stdout + stderr)
assert(name, stdout.empty?, "usage failure should not emit JSON", stdout)
assert(name, stderr.include?("--reviewed-scope-digest must be a lowercase SHA-256 hash"), "missing hash diagnostic", stderr)

$cases += 1
name = "unexpected positional arguments exit as usage error for claude"
stdout, stderr, status = run_judge("--provider", "claude", "extra")
assert(name, status.exitstatus == 2, "expected usage failure, got #{status.exitstatus}", stdout + stderr)
assert(name, stdout.empty?, "usage failure should not emit JSON", stdout)
assert(name, stderr.include?("unexpected positional arguments"), "missing positional-argument diagnostic", stderr)

$cases += 1
name = "missing provider returns schema-shaped unknown with nonzero status"
stdout, _stderr, status = run_judge
assert(name, status.exitstatus == 1, "expected missing provider to exit 1, got #{status.exitstatus}", stdout)
record = parse_json(name, stdout)
unless record.empty?
  assert_unknown_response(name, record, backend: "unknown", model: "unknown")
  assert_canonical_stdout(name, stdout, record)
end

$cases += 1
name = "invalid reviewed hash exits as usage error"
stdout, stderr, status = run_judge("--provider", "codex", "--reviewed-scope-digest", "ABC")
assert(name, status.exitstatus == 2, "expected usage failure, got #{status.exitstatus}", stdout + stderr)
assert(name, stdout.empty?, "usage failure should not emit JSON", stdout)
assert(name, stderr.include?("--reviewed-scope-digest must be a lowercase SHA-256 hash"), "missing hash diagnostic", stderr)

$cases += 1
name = "unexpected positional arguments exit as usage error"
stdout, stderr, status = run_judge("--provider", "codex", "extra")
assert(name, status.exitstatus == 2, "expected usage failure, got #{status.exitstatus}", stdout + stderr)
assert(name, stdout.empty?, "usage failure should not emit JSON", stdout)
assert(name, stderr.include?("unexpected positional arguments"), "missing positional-argument diagnostic", stderr)

if $failures.empty?
  puts "test-judge: #{$cases} cases passed"
else
  warn "test-judge: #{$failures.length} failures"
  warn $failures.join("\n\n")
  exit 1
end
