#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "metadata_lib"

ROOT = StrictModeMetadata.project_root
VALIDATOR = ROOT.join("tools/validate-metadata.rb")

$cases = 0
$failures = []

def copy_valid_fixture(root)
  FileUtils.cp_r(ROOT.join("schemas"), root)
  FileUtils.cp_r(ROOT.join("matrices"), root)
  FileUtils.cp(ROOT.join("README.md"), root.join("README.md"))
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
end

def read_record(path)
  JSON.parse(path.read)
end

def write_record(path, record)
  StrictModeMetadata.write_json(path, record)
end

def rehash_record!(record, hash_field)
  record[hash_field] = ""
  record[hash_field] = StrictModeMetadata.hash_record(record, hash_field)
end

def refresh_registry_spec_hashes(root)
  spec_hash = StrictModeMetadata.spec_hash(root)
  %w[schemas/schema-registry.json matrices/matrix-registry.json].each do |relative_path|
    path = root.join(relative_path)
    record = read_record(path)
    record["generated_from_spec_hash"] = spec_hash
    rehash_record!(record, "registry_hash")
    write_record(path, record)
  end
end

def with_fixture
  Dir.mktmpdir("strict-metadata-validator-") do |dir|
    root = Pathname.new(dir)
    copy_valid_fixture(root)
    yield root
  end
end

def run_raw_validator(*args)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, VALIDATOR.to_s, *args)
  [status.exitstatus, stdout + stderr]
end

def run_validator(root)
  run_raw_validator("--root", root.to_s)
end

def record_failure(name, message, output)
  $failures << "#{name}: #{message}\n#{output}"
end

def assert_no_stacktrace(name, output)
  return unless output.match?(/(^|\n)\S+\.rb:\d+:in `/) || output.include?("\n\tfrom ")

  record_failure(name, "unexpected Ruby stacktrace", output)
end

def expect_pass(name)
  $cases += 1
  with_fixture do |root|
    yield root if block_given?
    exitstatus, output = run_validator(root)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected exit 0, got #{exitstatus}", output) unless exitstatus.zero?
  end
end

def expect_fail(name, expected_output)
  $cases += 1
  with_fixture do |root|
    yield root
    exitstatus, output = run_validator(root)
    assert_no_stacktrace(name, output)
    record_failure(name, "expected exit 1, got #{exitstatus}", output) unless exitstatus == 1
    record_failure(name, "missing expected output #{expected_output.inspect}", output) unless output.include?(expected_output)
  end
end

def expect_cli_fail(name, expected_output, *args)
  $cases += 1
  exitstatus, output = run_raw_validator(*args)
  assert_no_stacktrace(name, output)
  record_failure(name, "expected exit 2, got #{exitstatus}", output) unless exitstatus == 2
  record_failure(name, "missing expected output #{expected_output.inspect}", output) unless output.include?(expected_output)
end

expect_pass("valid metadata")

expect_cli_fail("unknown CLI option is controlled failure", "invalid option: --definitely-unknown", "--definitely-unknown")

expect_cli_fail("missing CLI option argument is controlled failure", "missing argument: --root", "--root")

expect_fail("missing spec file is controlled failure", "specs/17-implementation-readiness.md: missing") do |root|
  root.join("specs/17-implementation-readiness.md").delete
end

expect_fail("spec directory is controlled failure", "specs/17-implementation-readiness.md: not a file") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  path.delete
  path.mkpath
end

expect_fail("missing spec subsection is controlled failure", "spec parse error: subsection not found: 17.4.1 Matrix Expansion Requirements") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!(/^### 17[.]4[.]1 Matrix Expansion Requirements\n.*?(?=^### 17[.]4[.]2 Provider Feature README Status And Proof Mapping\n)/m, "")
  path.write(text)
end

expect_fail("prefixed spec section heading is controlled failure", "spec parse error: section not found: 17.1 Schema Registry") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("## 17.1 Schema Registry\n", "## 17.1 Schema Registry Extra\n")
  path.write(text)
end

expect_fail("malformed spec table row is controlled failure", "spec parse error: 17.1 Schema Registry: malformed table row") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!(/^\| `metadata[.]schema-registry[.]v1` \|[^\n]+\n/, "| `metadata.schema-registry.v1` |\n")
  path.write(text)
end

expect_fail("extra spec table column is controlled failure", "spec parse error: 17.1 Schema Registry: malformed table row") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!(/^\| `metadata[.]schema-registry[.]v1` \|[^\n]+\n/) do |line|
    line.chomp.sub(/ \|$/, " | unexpected |") + "\n"
  end
  path.write(text)
end

expect_fail("empty spec table cell is controlled failure", "spec parse error: 17.4 Closed Matrix Registry: malformed table row") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
  replacement = "| `matrix.provider-feature-gate.v1` | | Keep README/provider matrix, installer hooks, and fixture proofs aligned | Refuse enforcement when README/installer/fixtures disagree on enabled provider capability | trailing |\n"
  path.write(text.sub(line, replacement))
end

expect_fail("unwrapped spec table id is controlled failure", "id cell must be backtick-wrapped") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `metadata.schema-registry.v1` |") }
    text.sub!(line, line.sub("`metadata.schema-registry.v1`", "metadata.schema-registry.v1"))
  end
  path.write(text)
end

expect_fail("unwrapped hash field cell is controlled failure", "malformed hash field cell") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `registry_hash` | metadata registry parser", "| registry_hash | metadata registry parser")
  path.write(text)
end

expect_fail("malformed required field cell is controlled failure", "malformed required field cell") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `schema_version`, `provider`", "| `event.normalized.v1` | schema_version, `provider`")
  path.write(text)
end

expect_fail("malformed referenced detail cell is controlled failure", "referenced term cell must be backtick-wrapped") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `state.checkpoint.v1` | `writer=\"repair\"` | `binding-literal` |", "| `state.checkpoint.v1` | writer=\"repair\" | `binding-literal` |")
  path.write(text)
end

expect_fail("duplicate structured profile item is controlled failure", "duplicate profile item") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `turn`; `tool`;", "| `event.normalized.v1` | `turn`; `turn`;")
  path.write(text)
end

expect_fail("malformed enum value cell is controlled failure", "malformed enum value cell") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `tool.write_intent` | `none`, `read`, `write`, `unknown` |", "| `event.normalized.v1` | `tool.write_intent` | none, `read`, `write`, `unknown` |")
  path.write(text)
end

expect_fail("malformed field detail cell is controlled failure", "field profile cell must be backtick-wrapped") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `permission.network` | `object` |", "| `event.normalized.v1` | permission.network | `object` |")
  path.write(text)
end

expect_fail("malformed variant rule cell is controlled failure", "variant rule cell must be backtick-wrapped") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `decision.internal.v1` | `allow empty text` | action=allow |", "| `decision.internal.v1` | allow empty text | action=allow |")
  path.write(text)
end

expect_fail("invalid schema id is controlled failure", "invalid schema id") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
    text.sub!(line, line.sub("`event.normalized.v1`", "`../escape.v1`"))
  end
  path.write(text)
end

expect_fail("invalid matrix id is controlled failure", "invalid matrix id") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
    text.sub!(line, line.sub("`matrix.provider-feature-gate.v1`", "`matrix.provider/escape.v1`"))
  end
  path.write(text)
end

expect_fail("duplicate schema registry row", "schema registry ids must be unique") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  text.sub!(line, line + line)
  path.write(text)
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate matrix registry row", "matrix registry ids must be unique") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("## 17.4 Closed Matrix Registry")
  end_index = text.index("### 17.4.1 Matrix Expansion Requirements")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema implementation profile row", "schema implementation profile ids must match schema registry ids") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("## 17.2 Schema Implementation Profiles")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema implementation profile row", "schema implementation profile ids must match schema registry ids") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("## 17.2 Schema Implementation Profiles")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  section.sub!(line, line + line.sub("event.normalized.v1", "event.extra-profile.v1"))
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema implementation profile row", "schema implementation profile ids must be unique") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("## 17.2 Schema Implementation Profiles")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema implementation profile clause", "schema implementation profile clauses must be unique for event.normalized.v1") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("provider/logical-event domains;", "provider/logical-event domains; provider/logical-event domains;")
  path.write(text)
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema required field row", "schema required field list ids must match schema registry ids") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1 Schema Required Field Lists")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema required field row", "schema required field list ids must match schema registry ids") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1 Schema Required Field Lists")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  section.sub!(line, line + line.sub("event.normalized.v1", "event.extra-required-fields.v1"))
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema required field row", "schema required field list ids must be unique") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1 Schema Required Field Lists")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema referenced detail row", "schema referenced details must match computed referenced terms") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1.1 Schema Referenced Term Details")
  end_index = text.index("### 17.2.2 Schema Structured Profile Details")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `state.checkpoint.v1` | `writer=\"repair\"` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema referenced detail row", "schema referenced details must match computed referenced terms") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1.1 Schema Referenced Term Details")
  end_index = text.index("### 17.2.2 Schema Structured Profile Details")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `state.checkpoint.v1` | `writer=\"repair\"` |") }
  section.sub!(line, line + "| `state.checkpoint.v1` | `extra referenced term` | `binding-literal` | `ledger checkpoint binding` | extra rule |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema referenced detail row", "schema referenced detail rows must be unique by schema id and referenced term") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1.1 Schema Referenced Term Details")
  end_index = text.index("### 17.2.2 Schema Structured Profile Details")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `state.checkpoint.v1` | `writer=\"repair\"` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema structured profile row", "schema structured profile ids must match schema registry ids") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2 Schema Structured Profile Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema structured profile row", "schema structured profile ids must match schema registry ids") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2 Schema Structured Profile Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  section.sub!(line, line + line.sub("event.normalized.v1", "event.extra-structured-profile.v1"))
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema structured profile row", "schema structured profile ids must be unique") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2 Schema Structured Profile Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema field detail row", "schema field details must match structured field profiles") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2.1 Schema Field Profile Details")
  end_index = text.index("### 17.2.3 Schema Enum Values")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` | `permission.network` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema field detail row", "schema field details must match structured field profiles") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2.1 Schema Field Profile Details")
  end_index = text.index("### 17.2.3 Schema Enum Values")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` | `permission.network` |") }
  section.sub!(line, line + "| `event.normalized.v1` | `extra field profile` | `object` | extra member | extra rule |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema field detail row", "schema field detail rows must be unique by schema id and field profile") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2.1 Schema Field Profile Details")
  end_index = text.index("### 17.2.3 Schema Enum Values")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` | `permission.network` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema enum value row", "schema enum value families must match structured enum families") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.3 Schema Enum Values")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` | `tool.write_intent` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema enum value row", "schema enum value families must match structured enum families") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.3 Schema Enum Values")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` | `tool.write_intent` |") }
  section.sub!(line, line + "| `event.normalized.v1` | `extra_enum` | `extra` |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema enum value row", "schema enum value rows must be unique by schema id and enum family") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.3 Schema Enum Values")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` | `tool.write_intent` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("missing schema variant rule row", "schema variant rule details must match structured variant requirements") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.4 Schema Variant Rule Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `decision.internal.v1` | `allow empty text` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra schema variant rule row", "schema variant rule details must match structured variant requirements") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.4 Schema Variant Rule Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `decision.internal.v1` | `allow empty text` |") }
  section.sub!(line, line + "| `decision.internal.v1` | `extra variant rule` | action=extra | extra required | extra forbidden |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate schema variant rule row", "schema variant rule rows must be unique by schema id and rule") do |root|
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.4 Schema Variant Rule Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `decision.internal.v1` | `allow empty text` |") }
  section.sub!(line, line + line)
  path.write(text[0...start_index] + section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate JSON key", "duplicate JSON object key") do |root|
  root.join("schemas/event.normalized.v1.schema.json").write("{\"schema_version\":1,\"schema_version\":1}\n")
end

expect_fail("schema profile is not object", "record must be a JSON object") do |root|
  root.join("schemas/event.normalized.v1.schema.json").write("[]\n")
end

expect_fail("schema profile false is not skipped", "record must be a JSON object") do |root|
  root.join("schemas/event.normalized.v1.schema.json").write("false\n")
end

expect_fail("schema registry null is not skipped", "record must be a JSON object") do |root|
  root.join("schemas/schema-registry.json").write("null\n")
end

expect_fail("matrix registry null is not skipped", "record must be a JSON object") do |root|
  root.join("matrices/matrix-registry.json").write("null\n")
end

expect_fail("registry ids wrong type", "ids must be an array of strings") do |root|
  path = root.join("schemas/schema-registry.json")
  record = read_record(path)
  record["ids"] = "not-an-array"
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("matrix registry ids wrong type", "ids must be an array of strings") do |root|
  path = root.join("matrices/matrix-registry.json")
  record = read_record(path)
  record["ids"] = "not-an-array"
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("missing schema registry id", "ids must match markdown schema registry") do |root|
  path = root.join("schemas/schema-registry.json")
  record = read_record(path)
  record["ids"] = record.fetch("ids")[0...-1]
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("missing matrix registry id", "ids must match markdown matrix registry") do |root|
  path = root.join("matrices/matrix-registry.json")
  record = read_record(path)
  record["ids"] = record.fetch("ids")[0...-1]
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("missing schema profile file", "event.normalized.v1.schema.json: missing") do |root|
  root.join("schemas/event.normalized.v1.schema.json").delete
end

expect_fail("schema profile directory is controlled failure", "cannot read") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  path.delete
  path.mkpath
end

expect_fail("schema registry directory is controlled failure", "cannot read") do |root|
  path = root.join("schemas/schema-registry.json")
  path.delete
  path.mkpath
end

expect_fail("matrix registry directory is controlled failure", "cannot read") do |root|
  path = root.join("matrices/matrix-registry.json")
  path.delete
  path.mkpath
end

expect_fail("extra schema profile file", "schema profile file set must match registry") do |root|
  source = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(source)
  record["schema_id"] = "event.extra.v1"
  rehash_record!(record, "profile_hash")
  write_record(root.join("schemas/event.extra.v1.schema.json"), record)
end

expect_fail("extra matrix profile file", "matrix profile file set must match registry") do |root|
  source = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  record = read_record(source)
  record["matrix_id"] = "matrix.provider-feature-extra.v1"
  rehash_record!(record, "profile_hash")
  write_record(root.join("matrices/matrix.provider-feature-extra.v1.matrix.json"), record)
end

expect_fail("extra schema profile field", "extra fields: unexpected") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["unexpected"] = true
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema filename id mismatch", "schema_id must match filename") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["schema_id"] = "event.other.v1"
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("wrong profile hash", "profile_hash mismatch") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["profile_hash"] = "0" * 64
  write_record(path, record)
end

expect_fail("schema profile required fields drift", "required_fields must match markdown required field list") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["required_fields"] = ["bogus_field"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile referenced terms drift", "referenced_terms must match markdown implementation profile") do |root|
  path = root.join("schemas/state.checkpoint.v1.schema.json")
  record = read_record(path)
  record["referenced_terms"] = ["bogus_term"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile referenced details drift", "referenced_details must match markdown referenced term detail table") do |root|
  path = root.join("schemas/state.checkpoint.v1.schema.json")
  record = read_record(path)
  record["referenced_details"]["writer=\"repair\""]["rules"] = ["bogus"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile referenced details wrong type", "referenced_details must be an object mapping referenced terms to kind/source/rule details") do |root|
  path = root.join("schemas/state.checkpoint.v1.schema.json")
  record = read_record(path)
  record["referenced_details"] = []
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile field profiles drift", "field_profiles must match markdown structured profile") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["field_profiles"] = ["bogus field profile"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile field details drift", "field_details must match markdown field detail table") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["field_details"]["permission.network"]["members"] = ["bogus"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile field details wrong type", "field_details must be an object mapping field profiles to shape/member/rule details") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["field_details"] = []
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile enum families drift", "enum_families must match markdown structured profile") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["enum_families"] = ["bogus enum"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile enum values drift", "enum_values must match markdown enum value table") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["enum_values"]["tool.write_intent"] = ["bogus"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile enum values wrong type", "enum_values must be an object mapping enum families to arrays of strings") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["enum_values"] = ["bogus"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile variant requirements drift", "variant_requirements must match markdown structured profile") do |root|
  path = root.join("schemas/approval.pending.v1.schema.json")
  record = read_record(path)
  record["variant_requirements"] = ["bogus variant"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile variant rules drift", "variant_rules must match markdown variant rule table") do |root|
  path = root.join("schemas/decision.internal.v1.schema.json")
  record = read_record(path)
  record["variant_rules"]["allow empty text"]["forbids"] = ["bogus"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile variant rules wrong type", "variant_rules must be an object mapping rules to selector/require/forbid arrays") do |root|
  path = root.join("schemas/decision.internal.v1.schema.json")
  record = read_record(path)
  record["variant_rules"] = []
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile variants drift", "variants must match markdown implementation profile") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["variants"] = ["bogus variant"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile variant details drift", "variant_details must match markdown implementation profile clause details") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["variant_details"]["provider/logical-event domains"]["kind"] = "bogus"
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile variant details wrong type", "variant_details must be an object mapping implementation clauses to index/kind/source/rule details") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["variant_details"] = []
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema profile nested profiles drift", "nested_profiles must match markdown implementation profile") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["nested_profiles"] = ["bogus.schema.v1"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("schema nested profiles reject matrix ids", "nested_profiles must match markdown implementation profile") do |root|
  path = root.join("schemas/config.runtime-env.v1.schema.json")
  record = read_record(path)
  record["nested_profiles"] = ["matrix.runtime-config-domain.v1"]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("unsupported JSON primitive is controlled failure", "profile_hash cannot be recomputed") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = read_record(path)
  record["schema_version"] = 1.5
  write_record(path, record)
end

expect_fail("stale registry spec hash", "generated_from_spec_hash must match specs/17-implementation-readiness.md") do |root|
  path = root.join("schemas/schema-registry.json")
  record = read_record(path)
  record["generated_from_spec_hash"] = "0" * 64
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("missing matrix profile file", "matrix.provider-feature-gate.v1.matrix.json: missing") do |root|
  root.join("matrices/matrix.provider-feature-gate.v1.matrix.json").delete
end

expect_fail("matrix profile directory is controlled failure", "cannot read") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  path.delete
  path.mkpath
end

expect_fail("matrix profile false is not skipped", "record must be a JSON object") do |root|
  root.join("matrices/matrix.provider-feature-gate.v1.matrix.json").write("false\n")
end

expect_fail("matrix filename id mismatch", "matrix_id must match filename") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  record = read_record(path)
  record["matrix_id"] = "matrix.provider-feature-extra.v1"
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("extra matrix profile field", "extra fields: unexpected") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  record = read_record(path)
  record["unexpected"] = true
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("wrong matrix profile hash", "profile_hash mismatch") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  record = read_record(path)
  record["profile_hash"] = "0" * 64
  write_record(path, record)
end

expect_fail("wrong matrix forbidden row classes", "forbidden_row_classes must match markdown expansion requirements") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  record = read_record(path)
  record["forbidden_row_classes"] = record.fetch("forbidden_row_classes")[0...-1]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("wrong matrix allowed row classes", "allowed_rows must match markdown expansion requirements") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  record = read_record(path)
  record["allowed_rows"] = record.fetch("allowed_rows")[0...-1]
  rehash_record!(record, "profile_hash")
  write_record(path, record)
end

expect_fail("missing matrix expansion row", "matrix expansion missing in specs/17-implementation-readiness.md") do |root|
  spec_path = root.join("specs/17-implementation-readiness.md")
  text = spec_path.read
  start_index = text.index("### 17.4.1 Matrix Expansion Requirements")
  end_index = text.index("### 17.4.2 Provider Feature README Status And Proof Mapping")
  expansion_section = text[start_index...end_index]
  expansion_section = expansion_section.lines.reject do |line|
    line.start_with?("| `matrix.provider-feature-gate.v1` |")
  end.join
  spec_path.write(text[0...start_index] + expansion_section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("extra matrix expansion row", "matrix expansion ids must match matrix registry ids") do |root|
  spec_path = root.join("specs/17-implementation-readiness.md")
  text = spec_path.read
  start_index = text.index("### 17.4.1 Matrix Expansion Requirements")
  end_index = text.index("### 17.4.2 Provider Feature README Status And Proof Mapping")
  expansion_section = text[start_index...end_index]
  line = expansion_section.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
  expansion_section.sub!(line, line.sub("matrix.provider-feature-gate.v1", "matrix.extra.v1") + line)
  spec_path.write(text[0...start_index] + expansion_section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("duplicate matrix expansion row", "matrix expansion ids must be unique") do |root|
  spec_path = root.join("specs/17-implementation-readiness.md")
  text = spec_path.read
  start_index = text.index("### 17.4.1 Matrix Expansion Requirements")
  end_index = text.index("### 17.4.2 Provider Feature README Status And Proof Mapping")
  expansion_section = text[start_index...end_index]
  line = expansion_section.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
  expansion_section.sub!(line, line + line)
  spec_path.write(text[0...start_index] + expansion_section + text[end_index..])
  refresh_registry_spec_hashes(root)
end

expect_fail("unsorted schema registry ids", "ids must be sorted and unique") do |root|
  path = root.join("schemas/schema-registry.json")
  record = read_record(path)
  record["ids"] = record.fetch("ids").reverse
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("unsorted matrix registry ids", "ids must be sorted and unique") do |root|
  path = root.join("matrices/matrix-registry.json")
  record = read_record(path)
  record["ids"] = record.fetch("ids").reverse
  rehash_record!(record, "registry_hash")
  write_record(path, record)
end

expect_fail("missing README is controlled failure", "README.md: missing") do |root|
  root.join("README.md").delete
end

expect_fail("README provider status drift", "README provider status cell is not mapped") do |root|
  path = root.join("README.md")
  path.write(path.read.sub("| Install/config merge | Planned |", "| Install/config merge | Planned soon |"))
end

expect_fail("README provider header drift", "README provider matrix header must match") do |root|
  path = root.join("README.md")
  path.write(path.read.sub("| Capability | Claude Code | Codex CLI | Required proof before enforcement |", "| Capability | Claude | Codex CLI | Required proof before enforcement |"))
end

expect_fail("README provider duplicate capability drift", "README provider matrix capabilities must be unique") do |root|
  path = root.join("README.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| Install/config merge |") }
  path.write(text.sub(line, line + line))
end

expect_fail("README provider missing capability drift", "README provider capability rows must match 17.4.2") do |root|
  path = root.join("README.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| FDR challenge |") }
  path.write(text.sub(line, ""))
end

expect_fail("README provider proof drift", "README provider proof cell is not mapped") do |root|
  path = root.join("README.md")
  path.write(path.read.sub("Structured config merge tests plus protected install baseline", "Structured config merge proof"))
end

if $failures.empty?
  puts "metadata validator tests passed (#{$cases} cases)"
  exit 0
end

warn $failures.join("\n\n")
exit 1
