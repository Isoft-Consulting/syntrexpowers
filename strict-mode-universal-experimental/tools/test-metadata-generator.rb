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
GENERATOR = ROOT.join("tools/generate-metadata.rb")
CHECKER = ROOT.join("tools/check-metadata-generated.rb")

$cases = 0
$failures = []

def copy_metadata_root(root)
  %w[schemas matrices].each { |dir| FileUtils.cp_r(ROOT.join(dir), root) }
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
end

def run_checker(root)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, CHECKER.to_s, "--root", root.to_s)
  [status.exitstatus, stdout + stderr]
end

def run_raw_tool(tool, *args)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, tool.to_s, *args)
  [status.exitstatus, stdout + stderr]
end

def run_generator(root)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR.to_s, "--root", root.to_s)
  [status.exitstatus, stdout + stderr]
end

def expect_command_fail(name, expected_output)
  $cases += 1
  Dir.mktmpdir("strict-metadata-generator-command-") do |dir|
    root = Pathname.new(dir)
    exitstatus, output = yield root
    assert_no_stacktrace(name, output)
    $failures << "#{name}: expected exit 1, got #{exitstatus}\n#{output}" unless exitstatus == 1
    $failures << "#{name}: missing expected output #{expected_output.inspect}\n#{output}" unless output.include?(expected_output)
  end
end

def expect_cli_fail(name, expected_output, tool, *args)
  $cases += 1
  exitstatus, output = run_raw_tool(tool, *args)
  assert_no_stacktrace(name, output)
  $failures << "#{name}: expected exit 2, got #{exitstatus}\n#{output}" unless exitstatus == 2
  $failures << "#{name}: missing expected output #{expected_output.inspect}\n#{output}" unless output.include?(expected_output)
end

def expect_command_pass(name)
  $cases += 1
  Dir.mktmpdir("strict-metadata-generator-command-") do |dir|
    root = Pathname.new(dir)
    exitstatus, output = yield root
    assert_no_stacktrace(name, output)
    $failures << "#{name}: expected exit 0, got #{exitstatus}\n#{output}" unless exitstatus.zero?
  end
end

def assert_no_stacktrace(name, output)
  return unless output.match?(/(^|\n)\S+\.rb:\d+:in `/) || output.include?("\n\tfrom ")

  $failures << "#{name}: unexpected Ruby stacktrace\n#{output}"
end

def with_fixture
  Dir.mktmpdir("strict-metadata-generator-") do |dir|
    root = Pathname.new(dir)
    copy_metadata_root(root)
    yield root
  end
end

def expect_pass(name)
  $cases += 1
  with_fixture do |root|
    yield root if block_given?
    exitstatus, output = run_checker(root)
    assert_no_stacktrace(name, output)
    $failures << "#{name}: expected exit 0, got #{exitstatus}\n#{output}" unless exitstatus.zero?
  end
end

def expect_fail(name, expected_output)
  $cases += 1
  with_fixture do |root|
    yield root
    exitstatus, output = run_checker(root)
    assert_no_stacktrace(name, output)
    $failures << "#{name}: expected exit 1, got #{exitstatus}\n#{output}" unless exitstatus == 1
    $failures << "#{name}: missing expected output #{expected_output.inspect}\n#{output}" unless output.include?(expected_output)
  end
end

expect_pass("generated metadata is reproducible")

expect_command_fail("missing generator spec is controlled failure", "specs/17-implementation-readiness.md: missing") do |root|
  run_generator(root)
end

expect_command_fail("missing checker spec is controlled failure", "specs/17-implementation-readiness.md: missing") do |root|
  run_checker(root)
end

expect_cli_fail("generator unknown CLI option is controlled failure", "invalid option: --definitely-unknown", GENERATOR, "--definitely-unknown")

expect_cli_fail("generator missing CLI option argument is controlled failure", "missing argument: --root", GENERATOR, "--root")

expect_cli_fail("checker unknown CLI option is controlled failure", "invalid option: --definitely-unknown", CHECKER, "--definitely-unknown")

expect_cli_fail("checker missing CLI option argument is controlled failure", "missing argument: --root", CHECKER, "--root")

expect_command_pass("generator compact table rows do not omit ids") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
    text.sub!(line, line.sub("| `event.normalized.v1` |", "|`event.normalized.v1` |"))
  end
  path.write(text)
  exitstatus, output = run_generator(root)
  unless root.join("schemas/event.normalized.v1.schema.json").file?
    $failures << "generator compact table rows do not omit ids: event schema was not generated\n#{output}"
  end
  [exitstatus, output]
end

expect_command_pass("generator nested profiles exclude matrix ids") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  exitstatus, output = run_generator(root)
  nested_matrix_ids = Dir[root.join("schemas/*.schema.json")].flat_map do |path|
    record = JSON.parse(File.read(path))
    record.fetch("nested_profiles").select { |id| id.start_with?("matrix.") }.map { |id| "#{path}: #{id}" }
  end
  unless nested_matrix_ids.empty?
    $failures << "generator nested profiles exclude matrix ids: #{nested_matrix_ids.join(", ")}\n#{output}"
  end
  [exitstatus, output]
end

expect_command_pass("generator separates required fields from referenced terms") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  exitstatus, output = run_generator(root)
  record = JSON.parse(root.join("schemas/state.checkpoint.v1.schema.json").read)
  required_fields = record.fetch("required_fields")
  referenced_terms = record.fetch("referenced_terms")
  referenced_details = record.fetch("referenced_details")
  unless required_fields.include?("source_ledger_record_hash") && required_fields.include?("checkpoint_hash")
    $failures << "generator separates required fields from referenced terms: checkpoint owned fields missing\n#{output}"
  end
  forbidden_required = %w[writer="repair" operation="checkpoint" related_record_hash]
  leaked_required = forbidden_required & required_fields
  unless leaked_required.empty?
    $failures << "generator separates required fields from referenced terms: binding terms leaked into required_fields: #{leaked_required.join(", ")}\n#{output}"
  end
  missing_references = forbidden_required - referenced_terms
  unless missing_references.empty?
    $failures << "generator separates required fields from referenced terms: referenced_terms missing #{missing_references.join(", ")}\n#{output}"
  end
  unless referenced_details.keys.sort == referenced_terms.sort
    $failures << "generator separates required fields from referenced terms: referenced_details keys do not match referenced_terms\n#{output}"
  end
  repair_detail = referenced_details.fetch("writer=\"repair\"")
  unless repair_detail.fetch("kind") == "binding-literal" &&
      repair_detail.fetch("rules").include?("source ledger writer requirement")
    $failures << "generator separates required fields from referenced terms: referenced_details missing writer repair binding detail\n#{output}"
  end
  [exitstatus, output]
end

expect_command_pass("generator emits structured profile metadata") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  exitstatus, output = run_generator(root)
  event_record = JSON.parse(root.join("schemas/event.normalized.v1.schema.json").read)
  baseline_record = JSON.parse(root.join("schemas/state.baseline.v1.schema.json").read)
  pending_record = JSON.parse(root.join("schemas/approval.pending.v1.schema.json").read)
  metadata_record = JSON.parse(root.join("schemas/metadata.schema-profile.v1.schema.json").read)
  unless event_record.fetch("field_profiles").include?("permission.network")
    $failures << "generator emits structured profile metadata: event field_profiles missing permission.network\n#{output}"
  end
  unless event_record.fetch("enum_families").include?("tool.write_intent")
    $failures << "generator emits structured profile metadata: event enum_families missing tool.write_intent\n#{output}"
  end
  unless event_record.fetch("field_details").keys.sort == event_record.fetch("field_profiles").sort
    $failures << "generator emits structured profile metadata: event field_details keys do not match field_profiles\n#{output}"
  end
  network_detail = event_record.fetch("field_details").fetch("permission.network")
  unless network_detail.fetch("shape") == "object" &&
      network_detail.fetch("members").include?("host") &&
      network_detail.fetch("members").include?("port")
    $failures << "generator emits structured profile metadata: event field_details missing permission.network shape or members\n#{output}"
  end
  unless event_record.fetch("enum_values").fetch("tool.write_intent") == %w[none read write unknown]
    $failures << "generator emits structured profile metadata: event enum_values missing exact tool.write_intent values\n#{output}"
  end
  unless event_record.fetch("enum_values").keys.sort == event_record.fetch("enum_families").sort
    $failures << "generator emits structured profile metadata: event enum_values keys do not match enum_families\n#{output}"
  end
  unless event_record.fetch("variant_rules").keys.sort == event_record.fetch("variant_requirements").sort
    $failures << "generator emits structured profile metadata: event variant_rules keys do not match variant_requirements\n#{output}"
  end
  unless event_record.fetch("variant_details").keys == event_record.fetch("variants")
    $failures << "generator emits structured profile metadata: event variant_details keys do not match variants\n#{output}"
  end
  domain_clause = "provider/logical-event domains"
  unless event_record.fetch("variant_details").fetch(domain_clause).fetch("kind") == "domain"
    $failures << "generator emits structured profile metadata: event variant_details missing domain classification\n#{output}"
  end
  markdown_wrapped = [event_record, baseline_record, pending_record, metadata_record].flat_map do |record|
    leaked_items = %w[field_profiles enum_families variant_requirements].flat_map { |field| record.fetch(field).grep(/`/) }
    leaked_items += record.fetch("referenced_details").flat_map do |term, detail|
      [term, detail.fetch("kind"), detail.fetch("source")] + detail.fetch("rules")
    end.grep(/`/)
    leaked_items += record.fetch("field_details").flat_map do |profile, detail|
      [profile, detail.fetch("shape")] + detail.fetch("members") + detail.fetch("rules")
    end.grep(/`/)
    leaked_items += record.fetch("variant_details").flat_map do |clause, detail|
      [detail.fetch("kind"), detail.fetch("source")] + detail.fetch("rules")
    end.grep(/`/)
    leaked_items + record.fetch("variant_rules").flat_map do |rule, detail|
      [rule] + detail.fetch("selectors") + detail.fetch("requires") + detail.fetch("forbids")
    end.grep(/`/)
  end
  unless markdown_wrapped.empty?
    $failures << "generator emits structured profile metadata: markdown code leaked: #{markdown_wrapped.join(", ")}\n#{output}"
  end
  unless baseline_record.fetch("variant_requirements").include?("protected baseline extras")
    $failures << "generator emits structured profile metadata: baseline variant_requirements missing protected baseline extras\n#{output}"
  end
  unless pending_record.fetch("variant_requirements").include?("quality-bypass extra fields")
    $failures << "generator emits structured profile metadata: pending variant_requirements missing quality-bypass extra fields\n#{output}"
  end
  quality_bypass_rule = pending_record.fetch("variant_rules").fetch("quality-bypass extra fields")
  unless quality_bypass_rule.fetch("selectors").include?("kind=quality-bypass") &&
      quality_bypass_rule.fetch("requires").include?("gate_context")
    $failures << "generator emits structured profile metadata: pending variant_rules missing quality-bypass predicates\n#{output}"
  end
  runtime_record = JSON.parse(root.join("schemas/config.runtime-env.v1.schema.json").read)
  unless runtime_record.fetch("enum_values").fetch("codex judge model") == ["gpt-5.3-codex-spark"]
    $failures << "generator emits structured profile metadata: runtime enum_values missing Codex Spark judge model\n#{output}"
  end
  [exitstatus, output]
end

expect_command_fail("checker spec directory is controlled failure", "specs/17-implementation-readiness.md: not a file") do |root|
  root.join("specs/17-implementation-readiness.md").mkpath
  run_checker(root)
end

expect_command_fail("generator output schemas path file is controlled failure", "generation error:") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  root.join("schemas").write("not-a-directory\n")
  run_generator(root)
end

expect_command_fail("generator output matrices path file leaves no partial schemas", "generation error:") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  root.join("matrices").write("not-a-directory\n")
  exitstatus, output = run_generator(root)
  if root.join("schemas/schema-registry.json").exist?
    $failures << "generator output matrices path file leaves no partial schemas: partial schema registry was written\n#{output}"
  end
  [exitstatus, output]
end

expect_command_fail("generator output schema file directory leaves no partial registry", "generation error:") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  root.join("schemas/event.normalized.v1.schema.json").mkpath
  exitstatus, output = run_generator(root)
  if root.join("schemas/schema-registry.json").exist? || root.join("matrices/matrix-registry.json").exist?
    $failures << "generator output schema file directory leaves no partial registry: partial registry was written\n#{output}"
  end
  [exitstatus, output]
end

expect_command_fail("generator output matrix file directory leaves no partial registry", "generation error:") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  root.join("matrices/matrix.provider-feature-gate.v1.matrix.json").mkpath
  exitstatus, output = run_generator(root)
  if root.join("schemas/schema-registry.json").exist? || root.join("matrices/matrix-registry.json").exist?
    $failures << "generator output matrix file directory leaves no partial registry: partial registry was written\n#{output}"
  end
  [exitstatus, output]
end

expect_command_fail("generator missing schema profile row is controlled failure", "schema implementation profile ids must match schema registry ids") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("## 17.2 Schema Implementation Profiles")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator missing schema required field row is controlled failure", "schema required field list ids must match schema registry ids") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1 Schema Required Field Lists")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator duplicate schema implementation profile clause is controlled failure", "schema implementation profile clauses must be unique for event.normalized.v1") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("provider/logical-event domains;", "provider/logical-event domains; provider/logical-event domains;")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator missing schema referenced detail row is controlled failure", "schema referenced details must match computed referenced terms") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1.1 Schema Referenced Term Details")
  end_index = text.index("### 17.2.2 Schema Structured Profile Details")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `state.checkpoint.v1` | `writer=\"repair\"` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator extra schema referenced detail row is controlled failure", "schema referenced details must match computed referenced terms") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.1.1 Schema Referenced Term Details")
  end_index = text.index("### 17.2.2 Schema Structured Profile Details")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `state.checkpoint.v1` | `writer=\"repair\"` |") }
  section.sub!(line, line + "| `state.checkpoint.v1` | `extra referenced term` | `binding-literal` | `ledger checkpoint binding` | extra rule |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator missing schema structured profile row is controlled failure", "schema structured profile ids must match schema registry ids") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2 Schema Structured Profile Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator missing schema field detail row is controlled failure", "schema field details must match structured field profiles") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2.1 Schema Field Profile Details")
  end_index = text.index("### 17.2.3 Schema Enum Values")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` | `permission.network` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator extra schema field detail row is controlled failure", "schema field details must match structured field profiles") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.2.1 Schema Field Profile Details")
  end_index = text.index("### 17.2.3 Schema Enum Values")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `event.normalized.v1` | `permission.network` |") }
  section.sub!(line, line + "| `event.normalized.v1` | `extra field profile` | `object` | extra member | extra rule |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator missing schema enum value row is controlled failure", "schema enum value families must match structured enum families") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.3 Schema Enum Values")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `event.normalized.v1` | `tool.write_intent` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator missing schema variant rule row is controlled failure", "schema variant rule details must match structured variant requirements") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.4 Schema Variant Rule Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `decision.internal.v1` | `allow empty text` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator extra schema variant rule row is controlled failure", "schema variant rule details must match structured variant requirements") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.2.4 Schema Variant Rule Details")
  end_index = text.index("## 17.3 Executable Metadata Layout")
  section = text[start_index...end_index]
  line = section.lines.find { |item| item.start_with?("| `decision.internal.v1` | `allow empty text` |") }
  section.sub!(line, line + "| `decision.internal.v1` | `extra variant rule` | action=extra | extra required | extra forbidden |\n")
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator missing matrix expansion row is controlled failure", "matrix expansion ids must match matrix registry ids") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  start_index = text.index("### 17.4.1 Matrix Expansion Requirements")
  end_index = text.index("### 17.4.2 Provider Feature README Status And Proof Mapping")
  section = text[start_index...end_index]
  section = section.lines.reject { |line| line.start_with?("| `matrix.provider-feature-gate.v1` |") }.join
  path.write(text[0...start_index] + section + text[end_index..])
  run_generator(root)
end

expect_command_fail("generator prefixed spec section heading is controlled failure", "spec parse error: section not found: 17.1 Schema Registry") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("## 17.1 Schema Registry\n", "## 17.1 Schema Registry Extra\n")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator duplicate schema registry row is controlled failure", "schema registry ids must be unique") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
  text.sub!(line, line + line)
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator unwrapped spec table id is controlled failure", "id cell must be backtick-wrapped") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `metadata.schema-registry.v1` |") }
    text.sub!(line, line.sub("`metadata.schema-registry.v1`", "metadata.schema-registry.v1"))
  end
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator unwrapped hash field cell is controlled failure", "malformed hash field cell") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `registry_hash` | metadata registry parser", "| registry_hash | metadata registry parser")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator malformed required field cell is controlled failure", "malformed required field cell") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `schema_version`, `provider`", "| `event.normalized.v1` | schema_version, `provider`")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator duplicate structured profile item is controlled failure", "duplicate profile item") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `turn`; `tool`;", "| `event.normalized.v1` | `turn`; `turn`;")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator malformed enum value cell is controlled failure", "malformed enum value cell") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `tool.write_intent` | `none`, `read`, `write`, `unknown` |", "| `event.normalized.v1` | `tool.write_intent` | none, `read`, `write`, `unknown` |")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator malformed referenced detail cell is controlled failure", "referenced term cell must be backtick-wrapped") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `state.checkpoint.v1` | `writer=\"repair\"` | `binding-literal` |", "| `state.checkpoint.v1` | writer=\"repair\" | `binding-literal` |")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator malformed field detail cell is controlled failure", "field profile cell must be backtick-wrapped") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `event.normalized.v1` | `permission.network` | `object` |", "| `event.normalized.v1` | permission.network | `object` |")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator malformed variant rule cell is controlled failure", "variant rule cell must be backtick-wrapped") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!("| `decision.internal.v1` | `allow empty text` | action=allow |", "| `decision.internal.v1` | allow empty text | action=allow |")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator duplicate enum value row is controlled failure", "schema enum value rows must be unique by schema id and enum family") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` | `tool.write_intent` |") }
  path.write(text.sub(line, line + line))
  run_generator(root)
end

expect_command_fail("generator duplicate referenced detail row is controlled failure", "schema referenced detail rows must be unique by schema id and referenced term") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `state.checkpoint.v1` | `writer=\"repair\"` |") }
  path.write(text.sub(line, line + line))
  run_generator(root)
end

expect_command_fail("generator duplicate field detail row is controlled failure", "schema field detail rows must be unique by schema id and field profile") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` | `permission.network` |") }
  path.write(text.sub(line, line + line))
  run_generator(root)
end

expect_command_fail("generator duplicate variant rule row is controlled failure", "schema variant rule rows must be unique by schema id and rule") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `decision.internal.v1` | `allow empty text` |") }
  path.write(text.sub(line, line + line))
  run_generator(root)
end

expect_command_fail("generator invalid schema id leaves no escaped output", "invalid schema id") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `event.normalized.v1` |") }
    text.sub!(line, line.sub("`event.normalized.v1`", "`../escape.v1`"))
  end
  path.write(text)
  exitstatus, output = run_generator(root)
  if root.join("escape.v1.schema.json").exist?
    $failures << "generator invalid schema id leaves no escaped output: escaped schema file was written\n#{output}"
  end
  [exitstatus, output]
end

expect_command_fail("generator invalid matrix id leaves no escaped output", "invalid matrix id") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  2.times do
    line = text.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
    text.sub!(line, line.sub("`matrix.provider-feature-gate.v1`", "`matrix.provider/escape.v1`"))
  end
  path.write(text)
  exitstatus, output = run_generator(root)
  if root.join("matrices/matrix.provider/escape.v1.matrix.json").exist?
    $failures << "generator invalid matrix id leaves no escaped output: escaped matrix file was written\n#{output}"
  end
  [exitstatus, output]
end

expect_command_fail("generator malformed spec table row is controlled failure", "spec parse error: 17.1 Schema Registry: malformed table row") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!(/^\| `metadata[.]schema-registry[.]v1` \|[^\n]+\n/, "| `metadata.schema-registry.v1` |\n")
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator extra spec table column is controlled failure", "spec parse error: 17.1 Schema Registry: malformed table row") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!(/^\| `metadata[.]schema-registry[.]v1` \|[^\n]+\n/) do |line|
    line.chomp.sub(/ \|$/, " | unexpected |") + "\n"
  end
  path.write(text)
  run_generator(root)
end

expect_command_fail("generator empty spec table cell is controlled failure", "spec parse error: 17.4 Closed Matrix Registry: malformed table row") do |root|
  root.join("specs").mkpath
  FileUtils.cp(ROOT.join("specs/17-implementation-readiness.md"), root.join("specs/17-implementation-readiness.md"))
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  line = text.lines.find { |item| item.start_with?("| `matrix.provider-feature-gate.v1` |") }
  replacement = "| `matrix.provider-feature-gate.v1` | | Keep README/provider matrix, installer hooks, and fixture proofs aligned | Refuse enforcement when README/installer/fixtures disagree on enabled provider capability | trailing |\n"
  path.write(text.sub(line, replacement))
  run_generator(root)
end

expect_command_fail("checker malformed spec table row is controlled failure", "spec parse error: 17.1 Schema Registry: malformed table row") do |root|
  copy_metadata_root(root)
  path = root.join("specs/17-implementation-readiness.md")
  text = path.read
  text.sub!(/^\| `metadata[.]schema-registry[.]v1` \|[^\n]+\n/, "| `metadata.schema-registry.v1` |\n")
  path.write(text)
  run_checker(root)
end

expect_fail("manual schema profile edit is detected", "schemas/event.normalized.v1.schema.json: generated content mismatch") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  record = JSON.parse(path.read)
  record["variants"] = ["manual drift"]
  record["profile_hash"] = ""
  record["profile_hash"] = StrictModeMetadata.hash_record(record, "profile_hash")
  StrictModeMetadata.write_json(path, record)
end

expect_fail("extra managed schema file is detected", "managed metadata file set mismatch") do |root|
  source = root.join("schemas/event.normalized.v1.schema.json")
  target = root.join("schemas/event.extra-generated.v1.schema.json")
  FileUtils.cp(source, target)
end

expect_fail("managed schema directory is controlled failure", "schemas/event.normalized.v1.schema.json: managed metadata path is not a file") do |root|
  path = root.join("schemas/event.normalized.v1.schema.json")
  path.delete
  path.mkpath
end

expect_fail("managed matrix directory is controlled failure", "matrices/matrix.provider-feature-gate.v1.matrix.json: managed metadata path is not a file") do |root|
  path = root.join("matrices/matrix.provider-feature-gate.v1.matrix.json")
  path.delete
  path.mkpath
end

if $failures.empty?
  puts "metadata generator tests passed (#{$cases} cases)"
  exit 0
end

warn $failures.join("\n\n")
exit 1
