#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require_relative "../tools/stub_detection_lib"

$cases = 0
$failures = []

def record_failure(name, message, detail = "")
  $failures << "#{name}: #{message}#{detail.empty? ? "" : "\n#{detail}"}"
end

def assert(name, condition, message, detail = "")
  record_failure(name, message, detail) unless condition
end

def scan(content, file_path, allowlist = { hashes: [], path_lines: [] })
  StrictModeStubDetection.scan(content: content, file_path: file_path, allowlist: allowlist)
end

$cases += 1
name = "TODO marker in PHP triggers finding"
findings = scan("function foo() {\n    // TODO: implement\n    return null;\n}\n", "/repo/app/Foo.php")
assert(name, findings.length == 1, "expected exactly one TODO finding, got #{findings.length}", findings.inspect)
assert(name, findings.first["label"] == "TODO/FIXME/XXX/HACK", "wrong label", findings.first.inspect)
assert(name, findings.first["line_number"] == 2, "wrong line number", findings.first.inspect)

$cases += 1
name = "FIXME marker in JS triggers finding"
findings = scan("export function bar() {\n    // FIXME: race condition\n}\n", "/repo/app/bar.ts")
assert(name, findings.length == 1, "expected one FIXME finding", findings.inspect)

$cases += 1
name = "PHP not-implemented exception triggers finding"
findings = scan("function notReady() {\n    throw new Exception('not implemented');\n}\n", "/repo/app/Service.php")
assert(name, findings.length >= 1, "expected php-not-implemented finding", findings.inspect)
labels = findings.map { |f| f["label"] }
assert(name, labels.include?("php-not-implemented"), "missing php-not-implemented label", labels.inspect)

$cases += 1
name = "Go panic stub triggers finding"
findings = scan("func DoStuff() {\n    panic(\"not implemented\")\n}\n", "/repo/svc/main.go")
assert(name, findings.any? { |f| f["label"] == "go-panic-stub" }, "missing go-panic-stub label", findings.inspect)

$cases += 1
name = "JS throw new Error stub triggers finding"
findings = scan("function f() {\n    throw new Error('TODO: implement');\n}\n", "/repo/web/app.ts")
labels = findings.map { |f| f["label"] }
assert(name, labels.include?("js-not-implemented"), "missing js-not-implemented label", labels.inspect)

$cases += 1
name = "Russian later-marker triggers finding"
findings = scan("function x() {\n    // потом сделаю валидацию\n}\n", "/repo/app/x.ts")
labels = findings.map { |f| f["label"] }
assert(name, labels.include?("later-marker"), "missing later-marker label", labels.inspect)

$cases += 1
name = "Non-scannable extension yields zero findings"
findings = scan("TODO: implement me", "/repo/README.md")
assert(name, findings.empty?, "expected no findings for .md file", findings.inspect)

$cases += 1
name = "Empty content yields zero findings"
findings = scan("", "/repo/app/foo.php")
assert(name, findings.empty?, "expected no findings for empty content", findings.inspect)

$cases += 1
name = "Content over max_bytes is skipped"
large = "TODO " * 200_000 # ~1MB
findings = StrictModeStubDetection.scan(content: large, file_path: "/repo/app/big.php", allowlist: { hashes: [], path_lines: [] }, max_bytes: 524_288)
assert(name, findings.empty?, "expected oversize content to be skipped", findings.length)

$cases += 1
name = "Allowlisted hash bypasses finding"
line = "    // TODO: implement"
hash = Digest::SHA256.hexdigest(line.strip)
findings = scan("function f() {\n#{line}\n}\n", "/repo/app/x.ts", { hashes: [hash], path_lines: [] })
assert(name, findings.empty?, "allowlisted hash should suppress finding", findings.inspect)

$cases += 1
name = "Non-matching hash leaves finding in place"
findings = scan("function f() {\n    // TODO: real\n}\n", "/repo/app/x.ts", { hashes: ["0" * 64], path_lines: [] })
assert(name, findings.length >= 1, "non-matching hash must not suppress", findings.inspect)

$cases += 1
name = "Per-line allow-stub marker is IGNORED at pre-write time (per stub-scan spec)"
# Spec specs/08-shared-core/01-stub-scan.md: "A current-turn edit that adds
# allow-stub: on the same line as a stub marker does not suppress the stub
# finding" + "If baseline comparison is unavailable for an edited file,
# allow-stub: on changed or newly added lines is ignored." Pre-write hook has
# no baseline comparison — must ignore the marker. Bypass только через
# hash-allowlist (protected config, agent cannot mutate within turn).
content = "function f() {\n    // TODO: real // allow-stub: legacy entry\n}\n"
findings = scan(content, "/repo/app/x.ts")
assert(name, findings.length >= 1, "allow-stub marker MUST NOT suppress finding at pre-write", findings.inspect)
assert(name, findings.first["label"] == "TODO/FIXME/XXX/HACK", "wrong label", findings.inspect)

$cases += 1
name = "extract_scannable_targets handles Write tool"
tool = { "name" => "Write", "kind" => "write", "file_path" => "/repo/app/a.ts", "content" => "code", "new_string" => "", "edit_count" => 0 }
targets = StrictModeStubDetection.extract_scannable_targets(tool)
assert(name, targets.length == 1, "expected one Write target", targets.inspect)
assert(name, targets.first.fetch("file_path") == "/repo/app/a.ts", "wrong file_path", targets.inspect)
assert(name, targets.first.fetch("content") == "code", "wrong content", targets.inspect)

$cases += 1
name = "extract_scannable_targets handles Edit tool"
tool = { "name" => "Edit", "kind" => "edit", "file_path" => "/repo/app/a.ts", "content" => "", "new_string" => "new code", "edit_count" => 1 }
targets = StrictModeStubDetection.extract_scannable_targets(tool)
assert(name, targets.length == 1, "expected one Edit target", targets.inspect)
assert(name, targets.first.fetch("content") == "new code", "wrong content", targets.inspect)

$cases += 1
name = "extract_scannable_targets returns empty for non-write tools"
tool = { "name" => "Bash", "kind" => "shell", "command" => "ls", "file_path" => "", "content" => "", "new_string" => "" }
targets = StrictModeStubDetection.extract_scannable_targets(tool)
assert(name, targets.empty?, "expected no targets for shell tool", targets.inspect)

$cases += 1
name = "extract_scannable_targets is kind-based not name-based — unknown name + write kind still scanned"
tool = { "name" => "FutureProprietaryWriter", "kind" => "write", "file_path" => "/repo/app/x.ts", "content" => "// TODO: trojan", "new_string" => "" }
targets = StrictModeStubDetection.extract_scannable_targets(tool)
assert(name, targets.length == 1, "expected one target for unknown-name write-kind", targets.inspect)
assert(name, targets.first.fetch("content") == "// TODO: trojan", "wrong content", targets.inspect)

$cases += 1
name = "extract_scannable_targets handles unknown name + edit kind"
tool = { "name" => "FutureEditTool", "kind" => "edit", "file_path" => "/repo/app/x.ts", "content" => "", "new_string" => "// FIXME: ignore me" }
targets = StrictModeStubDetection.extract_scannable_targets(tool)
assert(name, targets.length == 1, "expected one target for unknown-name edit-kind", targets.inspect)
assert(name, targets.first.fetch("content") == "// FIXME: ignore me", "wrong content", targets.inspect)

$cases += 1
name = "parse_allowlist_records extracts finding hashes"
records = [
  { "directive" => "finding", "finding_digest" => "a" * 64 },
  { "directive" => "finding", "finding_digest" => "b" * 64 },
  { "directive" => "finding", "finding_digest" => "a" * 64 } # дубль
]
allowlist = StrictModeStubDetection.parse_allowlist_records(records)
assert(name, allowlist.fetch(:hashes).length == 2, "expected 2 unique hashes", allowlist.inspect)
assert(name, allowlist.fetch(:hashes).include?("a" * 64), "missing hash a", allowlist.inspect)
assert(name, allowlist.fetch(:hashes).include?("b" * 64), "missing hash b", allowlist.inspect)

$cases += 1
name = "multiple findings in one file collected separately"
content = "// TODO: A\n// FIXME: B\nfunction x() { throw new Error('TODO impl'); }\n"
findings = scan(content, "/repo/app/x.ts")
assert(name, findings.length >= 2, "expected at least 2 findings", findings.inspect)

$cases += 1
name = "extract_raw_targets handles MultiEdit edits[] one target per edit"
tool_input = {
  "file_path" => "/repo/app/a.ts",
  "edits" => [
    { "old_string" => "x", "new_string" => "// TODO: from first edit" },
    { "old_string" => "y", "new_string" => "function ok() { return 1; }" }
  ]
}
targets = StrictModeStubDetection.extract_raw_targets("MultiEdit", tool_input)
assert(name, targets.length == 2, "expected one target per edit", targets.inspect)
assert(name, targets.all? { |t| t.fetch("file_path") == "/repo/app/a.ts" }, "all targets must share MultiEdit's file_path", targets.inspect)
assert(name, targets.first.fetch("content") == "// TODO: from first edit", "first target = first edit content", targets.inspect)
assert(name, targets.last.fetch("content") == "function ok() { return 1; }", "second target = second edit content", targets.inspect)

$cases += 1
name = "MultiEdit per-edit targets give accurate line_numbers per edit"
tool_input = {
  "file_path" => "/repo/app/a.ts",
  "edits" => [
    { "old_string" => "x", "new_string" => "line1\nline2\n// TODO: at edit1 line 3" },
    { "old_string" => "y", "new_string" => "// FIXME: at edit2 line 1" }
  ]
}
targets = StrictModeStubDetection.extract_raw_targets("MultiEdit", tool_input)
assert(name, targets.length == 2, "two edits → two targets", targets.inspect)
findings_1 = StrictModeStubDetection.scan(content: targets.first.fetch("content"), file_path: "/repo/app/a.ts")
findings_2 = StrictModeStubDetection.scan(content: targets.last.fetch("content"), file_path: "/repo/app/a.ts")
assert(name, findings_1.length == 1 && findings_1.first["line_number"] == 3, "edit1 TODO at line 3", findings_1.inspect)
assert(name, findings_2.length == 1 && findings_2.first["line_number"] == 1, "edit2 FIXME at line 1 of its own content", findings_2.inspect)

$cases += 1
name = "extract_raw_targets returns empty for MultiEdit without edits"
targets = StrictModeStubDetection.extract_raw_targets("MultiEdit", { "file_path" => "/x.ts" })
assert(name, targets.empty?, "expected no targets for empty edits", targets.inspect)

$cases += 1
name = "extract_raw_targets returns empty for MultiEdit without file_path"
targets = StrictModeStubDetection.extract_raw_targets("MultiEdit", { "edits" => [{ "new_string" => "x" }] })
assert(name, targets.empty?, "expected no targets without file_path", targets.inspect)

$cases += 1
name = "extract_raw_targets parses apply_patch Add File blocks"
patch = "*** Begin Patch\n*** Add File: /repo/app/new.ts\n+function f() {\n+    // TODO: implement\n+}\n*** End Patch\n"
targets = StrictModeStubDetection.extract_raw_targets("apply_patch", { "patch" => patch })
assert(name, targets.length == 1, "expected one apply_patch target", targets.inspect)
assert(name, targets.first.fetch("file_path") == "/repo/app/new.ts", "wrong file_path", targets.inspect)
assert(name, targets.first.fetch("content").include?("TODO: implement"), "content must include + lines", targets.inspect)

$cases += 1
name = "extract_raw_targets parses apply_patch with multiple Update blocks"
patch = "*** Update File: /repo/a.ts\n+const x = 1;\n*** Update File: /repo/b.ts\n+// FIXME: real\n+const y = 2;\n*** End Patch\n"
targets = StrictModeStubDetection.extract_raw_targets("apply_patch", { "patch" => patch })
assert(name, targets.length == 2, "expected two apply_patch targets", targets.inspect)
paths = targets.map { |t| t.fetch("file_path") }.sort
assert(name, paths == ["/repo/a.ts", "/repo/b.ts"], "wrong paths", targets.inspect)

$cases += 1
name = "apply_patch Move directive attributes content to NEW path, not old"
patch = "*** Update File: /repo/old.ts\n+// TODO: in renamed file\n+const x = 1;\n*** Move to: /repo/new.ts\n*** End Patch\n"
targets = StrictModeStubDetection.extract_raw_targets("apply_patch", { "patch" => patch })
assert(name, targets.length == 1, "expected one target after Move", targets.inspect)
assert(name, targets.first.fetch("file_path") == "/repo/new.ts", "Move must redirect content to NEW path", targets.inspect)
assert(name, targets.first.fetch("content").include?("TODO: in renamed file"), "content must survive Move", targets.inspect)

$cases += 1
name = "apply_patch Move with content AFTER move attributes correctly"
# Edge case: Move comes early, then Update block continues with more lines.
patch = "*** Update File: /repo/old.ts\n+// header line\n*** Move to: /repo/new.ts\n+// trailing line\n*** End Patch\n"
targets = StrictModeStubDetection.extract_raw_targets("apply_patch", { "patch" => patch })
assert(name, targets.length == 1, "expected one combined target", targets.inspect)
assert(name, targets.first.fetch("file_path") == "/repo/new.ts", "final path = new (post-Move)", targets.inspect)
assert(name, targets.first.fetch("content").include?("header line"), "buffer before Move preserved", targets.inspect)
assert(name, targets.first.fetch("content").include?("trailing line"), "buffer after Move preserved", targets.inspect)

$cases += 1
name = "extract_raw_targets returns empty for unsupported tool"
targets = StrictModeStubDetection.extract_raw_targets("Bash", { "command" => "ls" })
assert(name, targets.empty?, "expected no targets for Bash", targets.inspect)

$cases += 1
name = "extract_raw_targets is kind-based when normalized tool is passed — unknown name + multi-edit kind still parsed"
tool = { "name" => "FutureMultiEditor", "kind" => "multi-edit", "file_path" => "/repo/app/a.ts", "new_string" => "" }
tool_input = { "file_path" => "/repo/app/a.ts", "edits" => [{ "new_string" => "// TODO: trojan" }] }
targets = StrictModeStubDetection.extract_raw_targets(tool, tool_input)
assert(name, targets.length == 1, "expected one target for unknown-name multi-edit kind", targets.inspect)
assert(name, targets.first.fetch("content").include?("TODO: trojan"), "expected TODO content captured", targets.inspect)

$cases += 1
name = "extract_raw_targets is kind-based — unknown name + patch kind still parsed"
tool = { "name" => "FuturePatcher", "kind" => "patch" }
patch = "*** Add File: /repo/app/x.ts\n+function f() {\n+    // FIXME: real\n+}\n*** End Patch\n"
targets = StrictModeStubDetection.extract_raw_targets(tool, { "patch" => patch })
assert(name, targets.length == 1, "expected one patch target for unknown-name patch kind", targets.inspect)
assert(name, targets.first.fetch("content").include?("FIXME: real"), "expected FIXME content captured", targets.inspect)

$cases += 1
name = "scan picks up TODO in joined MultiEdit content"
joined = "function f() {\n    // TODO: implement\n}\nfunction g() { return 1; }"
findings = scan(joined, "/repo/app/a.ts")
assert(name, findings.length >= 1, "expected TODO finding in joined MultiEdit content", findings.inspect)

if $failures.empty?
  puts "stub detection tests passed (#{$cases} cases)"
else
  warn "stub detection tests: #{$failures.length} failures"
  warn $failures.join("\n\n")
  exit 1
end
