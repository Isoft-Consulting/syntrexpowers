#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/fdr_cycle_lib"
require_relative "../tools/fdr_import_lib"

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

def run_fdr(*args, env: {}, chdir: nil)
  options = {}
  options[:chdir] = chdir.to_s if chdir
  Open3.capture3(env, RbConfig.ruby, FDR.to_s, *args, **options)
end

def write_review(path, verdict: "clean", findings: [])
  json = JSON.pretty_generate({
    "provider" => "claude",
    "session_key" => "attacker-session",
    "cwd" => "/tmp/attacker",
    "project_dir" => "/tmp/attacker",
    "review_generated_at" => "2026-05-13T00:00:00Z",
    "reviewer" => "fixture-reviewer",
    "verdict" => verdict,
    "findings" => findings,
    "import_provenance" => { "provider" => "attacker" }
  })
  path.write("# FDR review\n\n```json strict-fdr-v1\n#{json}\n```\n")
end

$cases += 1
name = "strict-fdr import fails closed without matching trusted intent"
Dir.mktmpdir("strict-fdr-cli-") do |dir|
  root = Pathname.new(dir).realpath
  install_root = root.join("strict-mode")
  state_root = install_root.join("state")
  project = root.join("project")
  project.mkpath
  source = project.join("review.md")
  write_review(source)
  env = {
    "STRICT_INSTALL_ROOT" => install_root.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s,
    "STRICT_CWD" => project.to_s,
    "STRICT_PROJECT_DIR" => project.to_s
  }
  stdout, stderr, status = run_fdr("import", "--", "review.md", env: env, chdir: project)
  assert(name, status.exitstatus == 1, "expected missing-intent import to exit 1, got #{status.exitstatus}", stdout + stderr)
  assert(name, stderr.empty?, "expected no stderr for recognized failed import", stderr)
  begin
    record = JSON.parse(stdout)
    assert(name, record.fetch("schema_version") == 1, "schema_version mismatch", stdout)
    assert(name, record.fetch("mode") == "trusted-import", "mode mismatch", stdout)
    assert(name, record.fetch("decision") == "block", "decision mismatch", stdout)
    assert(name, record.fetch("reason_code") == "trusted-import-intent-missing", "reason_code mismatch", stdout)
    assert(name, record.fetch("source_path") == source.to_s, "source path mismatch", stdout)
  rescue JSON::ParserError, KeyError => e
    record_failure(name, "invalid missing-intent import JSON: #{e.message}", stdout)
  end
end

$cases += 1
name = "strict-fdr import normalizes artifact from ledger-backed pre-tool intent"
Dir.mktmpdir("strict-fdr-cli-") do |dir|
  root = Pathname.new(dir).realpath
  install_root = root.join("strict-mode")
  state_root = install_root.join("state")
  project = root.join("project")
  project.mkpath
  source = project.join("review.md")
  write_review(source)
  identity = StrictModeFdrCycle.session_identity("codex", { "thread_id" => "t1" })
  context = {
    "provider" => "codex",
    "session_key" => identity.fetch("session_key"),
    "raw_session_hash" => identity.fetch("raw_session_hash"),
    "cwd" => project.to_s,
    "project_dir" => project.to_s
  }
  source_record = StrictModeFdrImport.validate_source!("review.md", cwd: project, project_dir: project)
  intent = StrictModeFdrImport.append_import_intent!(
    state_root,
    context,
    turn_marker: "turn-1",
    install_root: install_root,
    source_arg: "review.md",
    source_realpath: source_record.fetch("realpath"),
    payload_hash: Digest::SHA256.hexdigest("payload")
  )
  env = {
    "STRICT_INSTALL_ROOT" => install_root.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s,
    "STRICT_CWD" => project.to_s,
    "STRICT_PROJECT_DIR" => project.to_s
  }
  stdout, stderr, status = run_fdr("import", "--", "review.md", env: env, chdir: project)
  assert(name, status.exitstatus == 0, "expected trusted import to exit 0, got #{status.exitstatus}", stdout + stderr)
  assert(name, stderr.empty?, "trusted import should not write stderr", stderr)
  begin
    record = JSON.parse(stdout)
    assert(name, record.fetch("mode") == "trusted-import", "mode mismatch", stdout)
    assert(name, record.fetch("decision") == "allow", "decision mismatch", stdout)
    artifact_path = Pathname.new(record.fetch("artifact_path"))
    rendered = artifact_path.read
    assert(name, rendered.start_with?("```json strict-fdr-v1\n"), "artifact does not start with strict fence", rendered)
    artifact = JSON.parse(rendered.match(/```json strict-fdr-v1\n(?<json>.*?)\n```/m)[:json])
    provenance = artifact.fetch("import_provenance")
    assert(name, artifact.fetch("provider") == "codex", "artifact trusted provider mismatch", artifact.inspect)
    assert(name, artifact.fetch("session_key") == identity.fetch("session_key"), "artifact session mismatch", artifact.inspect)
    assert(name, artifact.fetch("cwd") == project.to_s && artifact.fetch("project_dir") == project.to_s, "artifact path context mismatch", artifact.inspect)
    assert(name, artifact.fetch("verdict") == "clean" && artifact.fetch("finding_count") == 0, "artifact verdict mismatch", artifact.inspect)
    assert(name, provenance.fetch("provider") == "codex", "provenance accepted source provider", provenance.inspect)
    assert(name, provenance.fetch("import_intent_hash") == intent.fetch("intent_hash"), "provenance intent hash mismatch", provenance.inspect)
    assert(name, provenance.fetch("imported_artifact_hash") == record.fetch("imported_artifact_hash"), "imported hash mismatch", provenance.inspect)
    ledger_path = StrictModeFdrCycle.ledger_path(state_root, "codex", identity.fetch("session_key"))
    ledgers = StrictModeFdrCycle.load_session_ledger_records(ledger_path)
    assert(name, StrictModeFdrCycle.validate_session_ledger_chain(ledger_path).empty?, "session ledger chain invalid", ledgers.inspect)
    assert(name, ledgers.map { |entry| entry.fetch("writer") } == %w[strict-hook strict-fdr], "ledger writer sequence mismatch", ledgers.inspect)
    assert(name, ledgers.map { |entry| entry.fetch("target_class") } == %w[tool-intent-log fdr-artifact], "ledger target sequence mismatch", ledgers.inspect)
  rescue JSON::ParserError, KeyError, NoMethodError => e
    record_failure(name, "invalid trusted import result: #{e.message}", stdout)
  end
end

$cases += 1
name = "strict-fdr import rolls back artifact write when ledger append fails"
Dir.mktmpdir("strict-fdr-cli-") do |dir|
  root = Pathname.new(dir).realpath
  install_root = root.join("strict-mode")
  state_root = install_root.join("state")
  project = root.join("project")
  project.mkpath
  source = project.join("review.md")
  write_review(source)
  identity = StrictModeFdrCycle.session_identity("codex", { "thread_id" => "t1" })
  context = {
    "provider" => "codex",
    "session_key" => identity.fetch("session_key"),
    "raw_session_hash" => identity.fetch("raw_session_hash"),
    "cwd" => project.to_s,
    "project_dir" => project.to_s
  }
  source_record = StrictModeFdrImport.validate_source!("review.md", cwd: project, project_dir: project)
  StrictModeFdrImport.append_import_intent!(
    state_root,
    context,
    turn_marker: "turn-1",
    install_root: install_root,
    source_arg: "review.md",
    source_realpath: source_record.fetch("realpath"),
    payload_hash: Digest::SHA256.hexdigest("payload")
  )
  artifact_path = StrictModeFdrImport.artifact_path(state_root, "codex", identity.fetch("session_key"))
  artifact_path.dirname.mkpath
  artifact_path.write("old artifact\n")

  class << StrictModeFdrCycle
    alias __strict_fdr_import_original_append_session_ledger! append_session_ledger!

    def append_session_ledger!(*_args, **_kwargs)
      raise "forced ledger failure"
    end
  end
  begin
    begin
      StrictModeFdrImport.import!(
        source_arg: "review.md",
        install_root: install_root,
        state_root: state_root,
        cwd: project,
        project_dir: project
      )
      record_failure(name, "expected import to fail when ledger append fails")
    rescue StrictModeFdrImport::ImportError => e
      assert(name, e.reason_code == "trusted-import-invalid", "wrong failure reason", e.message)
      assert(name, artifact_path.read == "old artifact\n", "artifact content was not restored", artifact_path.read)
    end
  ensure
    class << StrictModeFdrCycle
      alias append_session_ledger! __strict_fdr_import_original_append_session_ledger!
      remove_method :__strict_fdr_import_original_append_session_ledger!
    end
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
