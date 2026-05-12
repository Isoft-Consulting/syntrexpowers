#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../tools/metadata_lib"
require_relative "../tools/preflight_record_lib"

ROOT = StrictModeMetadata.project_root

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def assert_no_stacktrace(name, output)
  return unless output.match?(/(^|\n)\S+\.rb:\d+:in `/) || output.include?("\n\tfrom ")

  record_failure(name, "unexpected Ruby stacktrace", output)
end

def assert_valid(name, record)
  errors = StrictModePreflightRecord.validate(record)
  assert(name, errors.empty?, "expected valid preflight record", errors.join("\n"))
end

def assert_invalid(name, record, expected)
  errors = StrictModePreflightRecord.validate(record)
  assert(name, errors.any? { |error| error.include?(expected) }, "expected error containing #{expected.inspect}", errors.join("\n"))
end

def deep_copy(record)
  JSON.parse(JSON.generate(record))
end

def run_case(name)
  $cases += 1
  yield name
rescue RuntimeError, SystemCallError, ArgumentError => e
  record_failure(name, "unexpected exception: #{e.message}")
end

def trusted_allow
  StrictModePreflightRecord.trusted_from_classifier(
    "pre-tool-use",
    { "decision" => "allow", "reason_code" => "shell-read-only-or-unmatched", "reason" => "", "metadata" => {} },
    { "kind" => "shell", "write_intent" => "read", "name" => "exec_command", "command" => "ls -la .", "file_paths" => [] }
  )
end

def trusted_block
  StrictModePreflightRecord.trusted_from_classifier(
    "pre-tool-use",
    { "decision" => "block", "reason_code" => "protected-root", "reason" => "protected root write", "metadata" => {} },
    { "kind" => "shell", "write_intent" => "write", "name" => "exec_command", "command" => "touch /protected/config", "file_paths" => [] }
  )
end

def trusted_unavailable_import_block
  StrictModePreflightRecord.trusted_from_classifier(
    "pre-tool-use",
    { "decision" => "block", "reason_code" => "trusted-import-unavailable", "reason" => "strict-fdr import requires the artifact importer", "metadata" => {} },
    { "kind" => "shell", "write_intent" => "write", "name" => "exec_command", "command" => "\"/strict/active/bin/strict-fdr\" import -- review.md", "file_paths" => [] }
  )
end

run_case("valid not-attempted preflight") do |name|
  assert_valid(name, StrictModePreflightRecord.not_attempted("stop"))
end

run_case("builder normalizes unsupported logical event to unknown") do |name|
  record = StrictModePreflightRecord.not_attempted("provider-native-future-event")
  assert_valid(name, record)
  assert(name, record.fetch("logical_event") == "unknown", "unsupported logical event was not normalized", record.inspect)
end

run_case("valid trusted allow preflight") do |name|
  assert_valid(name, trusted_allow)
end

run_case("valid trusted block preflight") do |name|
  assert_valid(name, trusted_block)
end

run_case("valid trusted unavailable import block preflight") do |name|
  assert_valid(name, trusted_unavailable_import_block)
end

run_case("valid untrusted baseline preflight") do |name|
  assert_valid(name, StrictModePreflightRecord.untrusted("pre-tool-use", "protected-baseline-untrusted", ["baseline hash mismatch"]))
end

run_case("extra field rejected") do |name|
  record = deep_copy(trusted_block)
  record["raw_command"] = "touch /protected/config"
  assert_invalid(name, record, "fields must be exact")
end

run_case("invalid hash rejected") do |name|
  record = deep_copy(trusted_block)
  record["command_hash"] = "abc"
  assert_invalid(name, record, "command_hash must be lowercase SHA-256")
end

run_case("hash mismatch rejected") do |name|
  record = deep_copy(trusted_block)
  record["reason_code"] = "destructive-command"
  assert_invalid(name, record, "preflight_hash mismatch")
end

run_case("not-attempted trusted coupling rejected") do |name|
  record = deep_copy(StrictModePreflightRecord.not_attempted("stop"))
  record["trusted"] = true
  record = StrictModePreflightRecord.with_hash(record)
  assert_invalid(name, record, "trusted=true requires attempted=true")
end

run_case("allow would-block coupling rejected") do |name|
  record = deep_copy(trusted_allow)
  record["would_block"] = true
  record = StrictModePreflightRecord.with_hash(record)
  assert_invalid(name, record, "would_block=true requires decision=block")
end

run_case("untrusted zero error hash rejected") do |name|
  record = deep_copy(StrictModePreflightRecord.untrusted("pre-tool-use", "provider-untrusted", ["provider proof missing"]))
  record["error_hash"] = StrictModePreflightRecord::ZERO_HASH
  record = StrictModePreflightRecord.with_hash(record)
  assert_invalid(name, record, "error_hash must be nonzero")
end

run_case("classifier reason decision coupling rejected") do |name|
  record = deep_copy(trusted_block)
  record["decision"] = "allow"
  record["would_block"] = false
  record = StrictModePreflightRecord.with_hash(record)
  assert_invalid(name, record, "block classifier reason_code requires decision=block")
end

run_case("CLI validates a valid preflight record") do |name|
  Dir.mktmpdir("strict-preflight-record-") do |dir|
    path = Pathname.new(dir).join("preflight.json")
    path.write(JSON.pretty_generate(trusted_allow) + "\n")
    stdout, stderr, status = Open3.capture3("ruby", ROOT.join("tools/validate-preflight-record.rb").to_s, "--path", path.to_s)
    output = stdout + stderr
    assert_no_stacktrace(name, output)
    assert(name, status.success?, "validator failed", output)
    assert(name, output.include?("preflight record validation passed"), "missing success output", output)
  end
end

run_case("CLI rejects duplicate keys without stacktrace") do |name|
  Dir.mktmpdir("strict-preflight-record-") do |dir|
    path = Pathname.new(dir).join("duplicate.json")
    path.write("{\"schema_version\":1,\"schema_version\":1}\n")
    stdout, stderr, status = Open3.capture3("ruby", ROOT.join("tools/validate-preflight-record.rb").to_s, "--path", path.to_s)
    output = stdout + stderr
    assert_no_stacktrace(name, output)
    assert(name, !status.success?, "duplicate-key payload unexpectedly passed", output)
    assert(name, output.include?("duplicate JSON object key"), "missing duplicate-key diagnostic", output)
  end
end

if $failures.empty?
  puts "preflight record tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
