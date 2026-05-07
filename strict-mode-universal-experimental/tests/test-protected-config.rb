#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/protected_config_lib"

ROOT = Pathname.new(__dir__).parent.expand_path
VALIDATOR = ROOT.join("tools/validate-protected-config.rb")

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
  Dir.mktmpdir("strict-protected-config-") do |dir|
    yield Pathname.new(dir).realpath
  end
end

def write_file(path, bytes)
  path.dirname.mkpath
  path.binwrite(bytes)
  path
end

def expect_valid(name, path, kind)
  status, output = run_cmd(VALIDATOR, "--kind", kind, "--path", path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected #{kind} validation success, got #{status}", output) unless status.zero?
end

def expect_invalid(name, path, kind, diagnostic)
  status, output = run_cmd(VALIDATOR, "--kind", kind, "--path", path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected #{kind} validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing diagnostic #{diagnostic.inspect}", output) unless output.include?(diagnostic)
end

with_root do |_root|
  name = "checked-in protected config templates validate"
  runtime_template = ROOT.join("templates/runtime.env.example")
  expect_valid(name, runtime_template, "runtime-env")
  runtime_records = StrictModeProtectedConfig.parse_file(runtime_template, kind: "runtime-env").fetch("records")
  runtime_settings = runtime_records.each_with_object({}) { |record, map| map[record.fetch("key")] = record.fetch("value") }
  record_failure(name, "Claude worker must default disabled until fixture proof") unless runtime_settings.fetch("STRICT_NO_CLAUDE_WORKER") == "1"
  record_failure(name, "Codex worker must default disabled until fixture proof") unless runtime_settings.fetch("STRICT_NO_CODEX_WORKER") == "1"
  {
    "protected-paths.txt" => "protected-paths",
    "destructive-patterns.txt" => "destructive-patterns",
    "stub-allowlist.txt" => "stub-allowlist",
    "filesystem-read-allowlist.txt" => "filesystem-read-allowlist",
    "network-allowlist.txt" => "network-allowlist"
  }.each do |file, kind|
    expect_valid(name, ROOT.join("templates/#{file}"), kind)
  end
end

with_root do |root|
  name = "runtime env whitelist validates values and rejects parser ambiguity"
  path = write_file(root.join("runtime.env"), <<~TEXT)
    STRICT_CAPTURE_RAW_PAYLOADS=1
    STRICT_CONFIRM_MIN_AGE_SEC=5
    STRICT_CONFIRM_MAX_AGE_SEC=600
    STRICT_CLAUDE_JUDGE_MODEL=claude-haiku-4-5-20251001
    STRICT_CODEX_JUDGE_MODEL=gpt-5.3-codex-spark
    STRICT_CLAUDE_WORKER_MODEL=claude-haiku-4-5-20251001
    STRICT_CODEX_WORKER_MODEL=gpt-5.3-codex-spark
    STRICT_WORKER_TIMEOUT_SEC=50
    STRICT_WORKER_CONTEXT_MAX_BYTES=65536
    STRICT_WORKER_RESULT_MAX_BYTES=16384
    STRICT_NO_CLAUDE_WORKER=1
    STRICT_NO_CODEX_WORKER=1
  TEXT
  result = StrictModeProtectedConfig.parse_file(path, kind: "runtime-env")
  record_failure(name, "expected trusted runtime env", result.inspect) unless result.fetch("trusted")
  record_failure(name, "expected sorted runtime records", result.inspect) unless result.fetch("records").map { |item| item.fetch("key") }.sort == result.fetch("records").map { |item| item.fetch("key") }

  expect_invalid(name, write_file(root.join("unknown.env"), "STRICT_MODE_PHASE=discovery\n"), "runtime-env", "runtime env key must be whitelisted")
  expect_invalid(name, write_file(root.join("duplicate.env"), "STRICT_CAPTURE_RAW_PAYLOADS=0\nSTRICT_CAPTURE_RAW_PAYLOADS=1\n"), "runtime-env", "appears more than once")
  expect_invalid(name, write_file(root.join("bad-int.env"), "STRICT_CONFIRM_MIN_AGE_SEC=61\n"), "runtime-env", "STRICT_CONFIRM_MIN_AGE_SEC must be integer 0..60")
  expect_invalid(name, write_file(root.join("bad-worker-int.env"), "STRICT_WORKER_CONTEXT_MAX_BYTES=1024\n"), "runtime-env", "STRICT_WORKER_CONTEXT_MAX_BYTES must be integer 4096..1048576")
  expect_invalid(name, write_file(root.join("bad-worker-model.env"), "STRICT_CODEX_WORKER_MODEL=gpt-5.3-codex\n"), "runtime-env", "STRICT_CODEX_WORKER_MODEL must be one of gpt-5.3-codex-spark")
  expect_invalid(name, write_file(root.join("claude-worker-enabled.env"), "STRICT_NO_CLAUDE_WORKER=0\n"), "runtime-env", "STRICT_NO_CLAUDE_WORKER=0 requires protected worker-invocation fixture proof")
  expect_invalid(name, write_file(root.join("codex-worker-enabled.env"), "STRICT_NO_CODEX_WORKER=0\n"), "runtime-env", "STRICT_NO_CODEX_WORKER=0 requires protected worker-invocation fixture proof")
  expect_invalid(name, write_file(root.join("bad-shell.env"), "STRICT_CODEX_JUDGE_MODEL=$(echo bad)\n"), "runtime-env", "unsupported shell or quoting syntax")
  expect_invalid(name, write_file(root.join("bad-cross.env"), "STRICT_CONFIRM_MIN_AGE_SEC=60\nSTRICT_CONFIRM_MAX_AGE_SEC=30\n"), "runtime-env", "must not exceed")
end

with_root do |root|
  name = "protected paths parser accepts exact directives and rejects unsafe paths"
  target_file = root.join("safe/file.txt")
  write_file(target_file, "data\n")
  target_dir = root.join("safe/tree")
  target_dir.mkpath
  path = write_file(root.join("protected-paths.txt"), "protect-file #{target_file}\nprotect-tree #{target_dir}/**\n")
  result = StrictModeProtectedConfig.parse_file(path, kind: "protected-paths")
  record_failure(name, "expected two protected path records", result.inspect) unless result.fetch("records").length == 2 && result.fetch("trusted")

  expect_invalid(name, write_file(root.join("relative.txt"), "protect-file relative/path\n"), "protected-paths", "path must be absolute")
  expect_invalid(name, write_file(root.join("glob.txt"), "protect-file #{root}/bad*\n"), "protected-paths", "shell, glob, or expansion")
  link = root.join("link")
  File.symlink(root.join("safe"), link)
  expect_invalid(name, write_file(root.join("symlink.txt"), "protect-file #{link}/file.txt\n"), "protected-paths", "symlink components")
end

with_root do |root|
  name = "destructive and stub config parsers reject malformed strict lines"
  destructive = write_file(root.join("destructive-patterns.txt"), "shell-ere rm[[:space:]]+-rf\nargv-token rm\n")
  result = StrictModeProtectedConfig.parse_file(destructive, kind: "destructive-patterns")
  record_failure(name, "expected destructive records", result.inspect) unless result.fetch("trusted") && result.fetch("records").length == 2
  expect_invalid(name, write_file(root.join("bad-regex.txt"), "shell-ere [unterminated\n"), "destructive-patterns", "does not compile")
  expect_invalid(name, write_file(root.join("bad-token.txt"), "argv-token rm;touch\n"), "destructive-patterns", "unsupported shell")

  good_digest = "a" * 64
  stub = write_file(root.join("stub-allowlist.txt"), "finding #{good_digest}\n")
  result = StrictModeProtectedConfig.parse_file(stub, kind: "stub-allowlist")
  record_failure(name, "expected stub allowlist digest", result.inspect) unless result.fetch("trusted") && result.fetch("records").first.fetch("finding_digest") == good_digest
  expect_invalid(name, write_file(root.join("bad-stub.txt"), "finding #{'A' * 64}\n"), "stub-allowlist", "lowercase SHA-256")
  expect_invalid(name, write_file(root.join("line-number-stub.txt"), "finding lib/a.rb:12\n"), "stub-allowlist", "lowercase SHA-256")
end

with_root do |root|
  name = "filesystem allowlist keeps valid entries and reports invalid entries as config errors"
  file = write_file(root.join("data/read.txt"), "data\n")
  tree = root.join("data/tree")
  tree.mkpath
  path = write_file(root.join("filesystem-read-allowlist.txt"), "read #{file}\nwrite #{file}\nread-tree #{tree}/**\n")
  result = StrictModeProtectedConfig.parse_file(path, kind: "filesystem-read-allowlist")
  record_failure(name, "expected allowlist to remain trusted", result.inspect) unless result.fetch("trusted")
  record_failure(name, "expected two valid read records", result.inspect) unless result.fetch("records").length == 2
  record_failure(name, "expected invalid write config error", result.inspect) unless result.fetch("config_errors").any? { |item| item.include?("unknown path directive") }

  link = root.join("read-link.txt")
  File.symlink(file, link)
  result = StrictModeProtectedConfig.parse_file(write_file(root.join("symlink-read.txt"), "read #{link}\n"), kind: "filesystem-read-allowlist")
  record_failure(name, "expected symlink read to be config error only", result.inspect) unless result.fetch("trusted") && result.fetch("records").empty? && result.fetch("config_errors").any? { |item| item.include?("symlink components") }

  protected_root = root.join("protected")
  protected_root.mkpath
  protected_file = write_file(protected_root.join("secret.txt"), "secret\n")
  result = StrictModeProtectedConfig.parse_file(
    write_file(root.join("protected-root-read.txt"), "read #{protected_file}\n"),
    kind: "filesystem-read-allowlist",
    protected_roots: [protected_root]
  )
  record_failure(name, "expected protected root read to be config error only", result.inspect) unless result.fetch("trusted") && result.fetch("records").empty? && result.fetch("config_errors").any? { |item| item.include?("outside protected roots") }

  hardlink = root.join("data/hardlink-secret.txt")
  File.link(protected_file, hardlink)
  stat = protected_file.stat
  result = StrictModeProtectedConfig.parse_file(
    write_file(root.join("protected-inode-read.txt"), "read #{hardlink}\n"),
    kind: "filesystem-read-allowlist",
    protected_inodes: [{ "dev" => stat.dev, "inode" => stat.ino }]
  )
  record_failure(name, "expected protected inode read to be config error only", result.inspect) unless result.fetch("trusted") && result.fetch("records").empty? && result.fetch("config_errors").any? { |item| item.include?("protected dev+inode") }

  status, output = run_cmd(VALIDATOR, "--kind", "filesystem-read-allowlist", "--path", path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected allowlist CLI to exit 0 with config warning, got #{status}", output) unless status.zero?
  record_failure(name, "missing allowlist warning", output) unless output.include?("protected config warning:")

  result = StrictModeProtectedConfig.parse_file(
    write_file(root.join("inline-comment-read.txt"), "read #{file}\nread #{file} # comment\n"),
    kind: "filesystem-read-allowlist"
  )
  record_failure(name, "expected allowlist inline comment to be config error only", result.inspect) unless result.fetch("trusted") && result.fetch("records").length == 1 && result.fetch("config_errors").any? { |item| item.include?("inline comments") }
end

with_root do |root|
  name = "network allowlist validates canonical connect tuples"
  path = write_file(root.join("network-allowlist.txt"), "connect https example.com 443\nconnect http 127.0.0.1 80\nconnect https 2001:db8::1 443\nconnect https *.example.com 443\nconnect https EXAMPLE.com 443\nconnect https example.com 70000\n")
  result = StrictModeProtectedConfig.parse_file(path, kind: "network-allowlist")
  record_failure(name, "expected network allowlist to remain trusted", result.inspect) unless result.fetch("trusted")
  record_failure(name, "expected duplicate-free valid network records", result.inspect) unless result.fetch("records").length == 3
  record_failure(name, "expected wildcard host config error", result.inspect) unless result.fetch("config_errors").any? { |item| item.include?("canonical lowercase hostname") }
  record_failure(name, "expected port config error", result.inspect) unless result.fetch("config_errors").any? { |item| item.include?("port") }
end

with_root do |root|
  name = "protected text base parser rejects unsafe bytes and line shapes"
  expect_invalid(name, write_file(root.join("nul.txt"), "finding #{'a' * 64}\0\n"), "stub-allowlist", "NUL byte")
  expect_invalid(name, write_file(root.join("comment.txt"), "finding #{'a' * 64} # comment\n"), "stub-allowlist", "inline comments")
  long_line = "finding #{'a' * 64}\n"
  status, output = run_cmd(VALIDATOR, "--kind", "stub-allowlist", "--path", write_file(root.join("long.txt"), long_line), "--line-max-bytes", "8")
  assert_no_stacktrace(name, output)
  record_failure(name, "expected line cap failure, got #{status}", output) unless status == 1
  record_failure(name, "missing line cap diagnostic", output) unless output.include?("STRICT_CONFIG_LINE_MAX_BYTES")
end

if $failures.empty?
  puts "protected config tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
