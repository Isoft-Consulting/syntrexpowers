#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

ROOT = Pathname.new(__dir__).parent.expand_path
FDR = ROOT.join("bin/strict-fdr")

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def run_fdr(*args)
  Open3.capture3(RbConfig.ruby, FDR.to_s, *args)
end

$cases += 1
name = "strict-fdr import fails closed while artifact importer is unavailable"
Dir.mktmpdir("strict-fdr-cli-") do |dir|
  source = Pathname.new(dir).join("review.md")
  source.write("# review\n")
  stdout, stderr, status = run_fdr("import", "--", source.to_s)
  assert(name, status.exitstatus == 1, "expected unavailable import to exit 1, got #{status.exitstatus}", stdout + stderr)
  assert(name, stderr.empty?, "expected no stderr for recognized unavailable import", stderr)
  begin
    record = JSON.parse(stdout)
    assert(name, record.fetch("schema_version") == 1, "schema_version mismatch", stdout)
    assert(name, record.fetch("mode") == "discovery-import-unavailable", "mode mismatch", stdout)
    assert(name, record.fetch("decision") == "block", "decision mismatch", stdout)
    assert(name, record.fetch("reason_code") == "trusted-import-unavailable", "reason_code mismatch", stdout)
    assert(name, record.fetch("source_path") == source.to_s, "source path mismatch", stdout)
  rescue JSON::ParserError, KeyError => e
    record_failure(name, "invalid unavailable import JSON: #{e.message}", stdout)
  end
end

$cases += 1
name = "strict-fdr usage errors do not emit trusted import JSON"
stdout, stderr, status = run_fdr("import")
assert(name, status.exitstatus == 2, "expected usage failure, got #{status.exitstatus}", stdout + stderr)
assert(name, stdout.empty?, "usage failure should not emit JSON", stdout)
assert(name, stderr.include?("usage: strict-fdr import -- <artifact-path>"), "missing usage diagnostic", stderr)

if $failures.empty?
  puts "test-fdr-cli: #{$cases} cases passed"
else
  warn "test-fdr-cli: #{$failures.length} failures"
  warn $failures.join("\n\n")
  exit 1
end
