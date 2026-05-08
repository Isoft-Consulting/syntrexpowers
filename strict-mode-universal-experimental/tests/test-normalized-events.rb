#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/metadata_lib"

ROOT = StrictModeMetadata.project_root
NORMALIZER = ROOT.join("tools/normalize-event.rb")

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
  Dir.mktmpdir("strict-normalized-") do |dir|
    root = Pathname.new(dir).realpath
    project = root.join("project")
    cwd = project.join("src")
    cwd.mkpath
    yield root, project, cwd
  end
end

def write_payload(root, name, payload)
  path = root.join("#{name}.json")
  path.write(JSON.generate(payload) + "\n")
  path
end

def expect_normalize(name, provider:, logical_event:, payload:)
  with_root do |root, project, cwd|
    source = write_payload(root, name.gsub(/[^a-z0-9]+/i, "-"), payload)
    status, stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", provider, "--logical-event", logical_event, "--source", source, "--cwd", cwd, "--project-dir", project)
    assert_no_stacktrace(name, output)
    unless status.zero?
      record_failure(name, "expected normalize success, got #{status}", output)
      next
    end
    event = JSON.parse(stdout)
    yield event, root, project, cwd, output
  end
end

def expect_normalize_fail(name, expected, provider:, logical_event:, payload:)
  with_root do |root, project, cwd|
    source = write_payload(root, name.gsub(/[^a-z0-9]+/i, "-"), payload)
    status, _stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", provider, "--logical-event", logical_event, "--source", source, "--cwd", cwd, "--project-dir", project)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected normalize failure, got #{status}", output) unless status == 1
    record_failure(name, "missing expected output #{expected.inspect}", output) unless output.include?(expected)
  end
end

expect_normalize(
  "Claude Write payload normalizes as write intent",
  provider: "claude",
  logical_event: "pre-tool-use",
  payload: {
    "hook_event_name" => "PreToolUse",
    "session_id" => "s1",
    "tool_name" => "Write",
    "tool_input" => {
      "file_path" => "app/models/user.rb",
      "content" => "class User\nend\n"
    }
  }
) do |event, _root, project, cwd, output|
  record_failure("Claude Write payload normalizes as write intent", "provider mismatch", output) unless event.fetch("provider") == "claude"
  record_failure("Claude Write payload normalizes as write intent", "cwd mismatch", output) unless event.fetch("cwd") == cwd.to_s
  record_failure("Claude Write payload normalizes as write intent", "project mismatch", output) unless event.fetch("project_dir") == project.to_s
  tool = event.fetch("tool")
  record_failure("Claude Write payload normalizes as write intent", "wrong tool kind", output) unless tool.fetch("kind") == "write"
  record_failure("Claude Write payload normalizes as write intent", "wrong write intent", output) unless tool.fetch("write_intent") == "write"
  record_failure("Claude Write payload normalizes as write intent", "missing file change", output) unless tool.fetch("file_changes").fetch(0).fetch("action") == "create"
end

expect_normalize(
  "Claude Bash payload keeps shell write intent unknown",
  provider: "claude",
  logical_event: "pre-tool-use",
  payload: {
    "hook_event_name" => "PreToolUse",
    "tool_name" => "Bash",
    "tool_input" => {
      "command" => "rm -rf tmp/build"
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  record_failure("Claude Bash payload keeps shell write intent unknown", "wrong tool kind", output) unless tool.fetch("kind") == "shell"
  record_failure("Claude Bash payload keeps shell write intent unknown", "shell was treated as safe", output) unless tool.fetch("write_intent") == "unknown"
  record_failure("Claude Bash payload keeps shell write intent unknown", "command missing", output) unless tool.fetch("command") == "rm -rf tmp/build"
end

expect_normalize(
  "Codex exec_command payload normalizes as shell",
  provider: "codex",
  logical_event: "pre-tool-use",
  payload: {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "exec_command",
    "tool_input" => {
      "command" => "touch build/out"
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  record_failure("Codex exec_command payload normalizes as shell", "wrong tool kind", output) unless tool.fetch("kind") == "shell"
  record_failure("Codex exec_command payload normalizes as shell", "wrong write intent", output) unless tool.fetch("write_intent") == "unknown"
  record_failure("Codex exec_command payload normalizes as shell", "command missing", output) unless tool.fetch("command") == "touch build/out"
end

expect_normalize(
  "Stop without tool uses none write intent",
  provider: "codex",
  logical_event: "stop",
  payload: {
    "event" => "stop",
    "thread_id" => "t1"
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  record_failure("Stop without tool uses none write intent", "wrong tool kind", output) unless tool.fetch("kind") == "unknown"
  record_failure("Stop without tool uses none write intent", "wrong write intent", output) unless tool.fetch("write_intent") == "none"
  record_failure("Stop without tool uses none write intent", "turn_id should stay untrusted", output) unless event.fetch("turn_id") == ""
end

expect_normalize(
  "raw payload hash uses source bytes",
  provider: "codex",
  logical_event: "stop",
  payload: {
    "event" => "stop",
    "thread_id" => "t1"
  }
) do |event, root, _project, _cwd, output|
  source = root.join("raw-payload-hash-uses-source-bytes.json")
  expected = Digest::SHA256.file(source).hexdigest
  record_failure("raw payload hash uses source bytes", "payload hash mismatch", output) unless event.fetch("raw").fetch("payload_sha256") == expected
end

expect_normalize(
  "unknown provider degrades tool confidence",
  provider: "unknown",
  logical_event: "pre-tool-use",
  payload: {
    "event" => "pre-tool-use",
    "tool_name" => "Write",
    "tool_input" => {
      "file_path" => "unsafe.txt"
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  record_failure("unknown provider degrades tool confidence", "kind should be unknown", output) unless tool.fetch("kind") == "unknown"
  record_failure("unknown provider degrades tool confidence", "intent should be unknown", output) unless tool.fetch("write_intent") == "unknown"
  record_failure("unknown provider degrades tool confidence", "file changes should not be trusted", output) unless tool.fetch("file_changes").empty?
end

expect_normalize(
  "Read tool is read intent",
  provider: "claude",
  logical_event: "pre-tool-use",
  payload: {
    "hook_event_name" => "PreToolUse",
    "tool_name" => "Read",
    "tool_input" => {
      "file_path" => "README.md"
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  record_failure("Read tool is read intent", "wrong kind", output) unless tool.fetch("kind") == "read"
  record_failure("Read tool is read intent", "wrong intent", output) unless tool.fetch("write_intent") == "read"
end

expect_normalize(
  "Apply patch extracts patch file changes",
  provider: "codex",
  logical_event: "pre-tool-use",
  payload: {
    "event" => "pre-tool-use",
    "tool_name" => "apply_patch",
    "tool_input" => {
      "patch" => "*** Begin Patch\n*** Add File: lib/new_file.rb\n+puts 'x'\n*** End Patch\n"
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  change = tool.fetch("file_changes").fetch(0)
  record_failure("Apply patch extracts patch file changes", "wrong kind", output) unless tool.fetch("kind") == "patch"
  record_failure("Apply patch extracts patch file changes", "wrong action", output) unless change.fetch("action") == "create"
  record_failure("Apply patch extracts patch file changes", "wrong path", output) unless change.fetch("path") == "lib/new_file.rb"
end

expect_normalize(
  "Write payload file_paths array creates target changes",
  provider: "codex",
  logical_event: "pre-tool-use",
  payload: {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "write",
    "tool_input" => {
      "file_paths" => ["lib/a.rb", "lib/b.rb"]
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  paths = tool.fetch("file_paths")
  actions = tool.fetch("file_changes").map { |change| change.fetch("action") }
  record_failure("Write payload file_paths array creates target changes", "wrong kind", output) unless tool.fetch("kind") == "write"
  record_failure("Write payload file_paths array creates target changes", "wrong paths", output) unless paths == ["lib/a.rb", "lib/b.rb"]
  record_failure("Write payload file_paths array creates target changes", "wrong actions", output) unless actions == %w[create create]
end

expect_normalize(
  "Apply patch move extracts rename source and destination",
  provider: "codex",
  logical_event: "pre-tool-use",
  payload: {
    "event" => "pre-tool-use",
    "thread_id" => "t1",
    "tool_name" => "apply_patch",
    "tool_input" => {
      "patch" => "*** Begin Patch\n*** Update File: lib/old.rb\n*** Move to: lib/new.rb\n@@\n-old\n+new\n*** End Patch\n"
    }
  }
) do |event, _root, _project, _cwd, output|
  tool = event.fetch("tool")
  change = tool.fetch("file_changes").fetch(0)
  record_failure("Apply patch move extracts rename source and destination", "wrong action", output) unless change.fetch("action") == "rename"
  record_failure("Apply patch move extracts rename source and destination", "wrong old path", output) unless change.fetch("old_path") == "lib/old.rb"
  record_failure("Apply patch move extracts rename source and destination", "wrong new path", output) unless change.fetch("new_path") == "lib/new.rb"
  record_failure("Apply patch move extracts rename source and destination", "wrong path projection", output) unless tool.fetch("file_paths") == ["lib/new.rb", "lib/old.rb"]
end

expect_normalize(
  "Permission request mirrors tool fields with unknown approval by default",
  provider: "codex",
  logical_event: "permission-request",
  payload: {
    "event" => "permission-request",
    "request_id" => "r1",
    "tool_name" => "Bash",
    "tool_input" => {
      "command" => "touch build/out"
    }
  }
) do |event, _root, _project, _cwd, output|
  permission = event.fetch("permission")
  record_failure("Permission request mirrors tool fields with unknown approval by default", "wrong operation", output) unless permission.fetch("operation") == "shell"
  record_failure("Permission request mirrors tool fields with unknown approval by default", "wrong requested tool kind", output) unless permission.fetch("requested_tool_kind") == "shell"
  record_failure("Permission request mirrors tool fields with unknown approval by default", "wrong can_approve", output) unless permission.fetch("can_approve") == "unknown"
end

expect_normalize(
  "Permission request normalizes network URL details",
  provider: "codex",
  logical_event: "permission-request",
  payload: {
    "event" => "permission-request",
    "request_id" => "r-net",
    "operation" => "network",
    "access_mode" => "network-connect",
    "url" => "https://Example.COM/api"
  }
) do |event, _root, _project, _cwd, output|
  permission = event.fetch("permission")
  network = permission.fetch("network")
  record_failure("Permission request normalizes network URL details", "wrong operation", output) unless permission.fetch("operation") == "network"
  record_failure("Permission request normalizes network URL details", "wrong access mode", output) unless permission.fetch("access_mode") == "network-connect"
  record_failure("Permission request normalizes network URL details", "wrong scheme", output) unless network.fetch("scheme") == "https"
  record_failure("Permission request normalizes network URL details", "wrong host", output) unless network.fetch("host") == "example.com"
  record_failure("Permission request normalizes network URL details", "wrong port", output) unless network.fetch("port") == 443
  record_failure("Permission request normalizes network URL details", "wrong network operation", output) unless network.fetch("operation") == "connect"
end

expect_normalize(
  "Permission request normalizes filesystem target details",
  provider: "codex",
  logical_event: "permission-request",
  payload: {
    "event" => "permission-request",
    "request_id" => "r-fs",
    "operation" => "filesystem",
    "access_mode" => "write",
    "filesystem" => {
      "paths" => ["src/app.rb"],
      "recursive" => false,
      "scope" => "file"
    }
  }
) do |event, _root, _project, _cwd, output|
  permission = event.fetch("permission")
  filesystem = permission.fetch("filesystem")
  record_failure("Permission request normalizes filesystem target details", "wrong operation", output) unless permission.fetch("operation") == "filesystem"
  record_failure("Permission request normalizes filesystem target details", "wrong requested paths", output) unless permission.fetch("requested_paths") == ["src/app.rb"]
  record_failure("Permission request normalizes filesystem target details", "wrong filesystem paths", output) unless filesystem.fetch("paths") == ["src/app.rb"]
  record_failure("Permission request normalizes filesystem target details", "wrong filesystem access", output) unless filesystem.fetch("access_mode") == "write"
  record_failure("Permission request normalizes filesystem target details", "wrong recursive", output) unless filesystem.fetch("recursive") == "false"
  record_failure("Permission request normalizes filesystem target details", "wrong scope", output) unless filesystem.fetch("scope") == "file"
end

expect_normalize_fail(
  "logical event mismatch is controlled failure",
  "logical event mismatch",
  provider: "claude",
  logical_event: "stop",
  payload: {
    "hook_event_name" => "PreToolUse",
    "tool_name" => "Write"
  }
)

with_root do |root, project, cwd|
  name = "duplicate JSON payload keys are controlled failure"
  source = root.join("duplicate.json")
  source.write("{\"event\":\"stop\",\"event\":\"again\"}\n")
  status, _stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", "codex", "--logical-event", "stop", "--source", source, "--cwd", cwd, "--project-dir", project)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected failure, got #{status}", output) unless status == 1
  record_failure(name, "missing duplicate key diagnostic", output) unless output.include?("duplicate JSON object key")
end

with_root do |root, project, cwd|
  name = "cwd outside project is controlled failure"
  source = write_payload(root, "outside-cwd", { "event" => "stop" })
  outside = root.join("outside")
  outside.mkpath
  status, _stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", "codex", "--logical-event", "stop", "--source", source, "--cwd", outside, "--project-dir", project)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected failure, got #{status}", output) unless status == 1
  record_failure(name, "missing cwd diagnostic", output) unless output.include?("cwd must be equal to or inside project_dir")
end

with_root do |root, project, cwd|
  name = "cwd project symlink aliases normalize before containment"
  source = write_payload(root, "symlink-cwd", { "event" => "stop" })
  alias_project = root.join("project-alias")
  File.symlink(project, alias_project)
  alias_cwd = alias_project.join("src")
  status, stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", "codex", "--logical-event", "stop", "--source", source, "--cwd", cwd, "--project-dir", alias_project)
  assert_no_stacktrace(name, output)
  if status.zero?
    event = JSON.parse(stdout)
    record_failure(name, "cwd was not canonicalized", output) unless event.fetch("cwd") == cwd.realpath.to_s
    record_failure(name, "project_dir was not canonicalized", output) unless event.fetch("project_dir") == project.realpath.to_s
  else
    record_failure(name, "expected symlink-alias containment success, got #{status}", output)
  end

  status, stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", "codex", "--logical-event", "stop", "--source", source, "--cwd", alias_cwd, "--project-dir", project)
  assert_no_stacktrace("#{name} inverse", output)
  if status.zero?
    event = JSON.parse(stdout)
    record_failure(name, "alias cwd was not canonicalized", output) unless event.fetch("cwd") == cwd.realpath.to_s
    record_failure(name, "real project_dir mismatch", output) unless event.fetch("project_dir") == project.realpath.to_s
  else
    record_failure(name, "expected inverse symlink-alias containment success, got #{status}", output)
  end
end

with_root do |root, _project, _cwd|
  name = "normalized validator rejects extra top-level fields"
  event_path = root.join("event.json")
  event_path.write(JSON.pretty_generate({
    "schema_version" => 1,
    "provider" => "codex",
    "logical_event" => "stop",
    "raw_event" => "stop",
    "session_id" => "",
    "parent_session_id" => "",
    "turn_id" => "",
    "cwd" => root.to_s,
    "project_dir" => root.to_s,
    "transcript_path" => "",
    "turn" => { "assistant_text" => "", "assistant_text_bytes" => 0, "assistant_text_truncated" => 0, "edit_count" => 0, "has_fdr_context" => false },
    "tool" => { "name" => "", "kind" => "unknown", "write_intent" => "none", "command" => "", "file_path" => "", "file_paths" => [], "file_changes" => [], "content" => "", "old_string" => "", "new_string" => "", "patch" => "" },
    "permission" => { "request_id" => "", "operation" => "unknown", "access_mode" => "unknown", "requested_tool_kind" => "unknown", "requested_command" => "", "requested_paths" => ["unknown"], "filesystem" => { "access_mode" => "unknown", "paths" => ["unknown"], "recursive" => "unknown", "scope" => "unknown" }, "network" => { "scheme" => "unknown", "host" => "unknown", "port" => "unknown", "operation" => "unknown", "url" => "unknown" }, "can_approve" => "unknown" },
    "prompt" => { "text" => "" },
    "assistant" => { "last_message" => "" },
    "raw" => { "payload_sha256" => "0" * 64, "event_name" => "stop", "logical_event_mismatch" => false, "provider_indicators" => [] },
    "extra" => true
  }) + "\n")
  status, _stdout, _stderr, output = run_cmd(NORMALIZER, "--validate-normalized", event_path)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected validation failure, got #{status}", output) unless status == 1
  record_failure(name, "missing exact field diagnostic", output) unless output.include?("event fields must be exact")
end

with_root do |root, project, cwd|
  name = "normalized validator rejects invalid network port"
  source = write_payload(root, "valid-stop", { "event" => "stop" })
  status, stdout, _stderr, output = run_cmd(NORMALIZER, "--provider", "codex", "--logical-event", "stop", "--source", source, "--cwd", cwd, "--project-dir", project)
  assert_no_stacktrace(name, output)
  if status.zero?
    event = JSON.parse(stdout)
    event["permission"]["network"]["port"] = "443"
    event_path = root.join("bad-network.json")
    event_path.write(JSON.pretty_generate(event) + "\n")
    validate_status, _validate_stdout, _validate_stderr, validate_output = run_cmd(NORMALIZER, "--validate-normalized", event_path)
    assert_no_stacktrace(name, validate_output)
    record_failure(name, "expected validation failure, got #{validate_status}", validate_output) unless validate_status == 1
    record_failure(name, "missing network port diagnostic", validate_output) unless validate_output.include?("network.port")
  else
    record_failure(name, "setup normalize failed", output)
  end
end

if $failures.empty?
  puts "normalized event tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
