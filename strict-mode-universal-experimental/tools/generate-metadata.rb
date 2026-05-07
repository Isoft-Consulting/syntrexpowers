#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "metadata_lib"

include StrictModeMetadata

options = { root: StrictModeMetadata.project_root }
parser = OptionParser.new do |option_parser|
  option_parser.banner = "Usage: generate-metadata.rb [--root PATH]"
  option_parser.on("--root PATH", "Generate metadata rooted at PATH") do |root|
    options[:root] = Pathname.new(root).expand_path
  end
end

begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
  exit 2
end

root = Pathname.new(options.fetch(:root)).expand_path
spec_path = StrictModeMetadata.spec_path(root)
unless spec_path.exist?
  warn "#{spec_path}: missing"
  exit 1
end
unless spec_path.file?
  warn "#{spec_path}: not a file"
  exit 1
end

begin
  spec_text = spec_path.read
  spec_hash = Digest::SHA256.hexdigest(spec_path.binread)
rescue SystemCallError, RuntimeError => e
  warn "#{spec_path}: spec parse error: #{e.message}"
  exit 1
end

begin
  schema_rows = StrictModeMetadata.schema_registry_rows(spec_text)
  schema_profile_rows = StrictModeMetadata.schema_profile_rows(spec_text)
  schema_profiles = schema_profile_rows.to_h { |row| [row["id"], row["summary"]] }
  schema_required_field_rows = StrictModeMetadata.schema_required_field_rows(spec_text)
  schema_required_fields = schema_required_field_rows.to_h { |row| [row["id"], row["required_fields"]] }
  schema_referenced_detail_rows = StrictModeMetadata.schema_referenced_detail_rows(spec_text)
  schema_structured_profile_rows = StrictModeMetadata.schema_structured_profile_rows(spec_text)
  schema_structured_profiles = schema_structured_profile_rows.to_h { |row| [row["id"], row] }
  schema_field_detail_rows = StrictModeMetadata.schema_field_detail_rows(spec_text)
  schema_enum_value_rows = StrictModeMetadata.schema_enum_value_rows(spec_text)
  schema_variant_rule_rows = StrictModeMetadata.schema_variant_rule_rows(spec_text)
  matrix_rows = StrictModeMetadata.matrix_registry_rows(spec_text)
  matrix_expansion_rows = StrictModeMetadata.matrix_expansion_rows(spec_text)
  matrix_expansions = matrix_expansion_rows.to_h { |row| [row["id"], row] }
rescue RuntimeError => e
  warn "#{spec_path}: spec parse error: #{e.message}"
  exit 1
end

preflight_errors = []
schema_row_ids = schema_rows.map { |row| row["id"] }
schema_profile_ids = schema_profile_rows.map { |row| row["id"] }
preflight_errors << "schema registry ids must be unique" unless schema_row_ids == schema_row_ids.uniq
preflight_errors << "schema implementation profile ids must be unique" unless schema_profile_ids == schema_profile_ids.uniq
preflight_errors << "schema implementation profile ids must match schema registry ids" unless schema_profile_ids.sort == schema_row_ids.sort
schema_profile_rows.each do |row|
  clauses = StrictModeMetadata.split_profile_text(row["summary"])
  preflight_errors << "schema implementation profile clauses must be unique for #{row["id"]}" unless clauses == clauses.uniq
end
schema_required_field_ids = schema_required_field_rows.map { |row| row["id"] }
preflight_errors << "schema required field list ids must be unique" unless schema_required_field_ids == schema_required_field_ids.uniq
preflight_errors << "schema required field list ids must match schema registry ids" unless schema_required_field_ids.sort == schema_row_ids.sort
schema_referenced_detail_keys = schema_referenced_detail_rows.map { |row| [row["id"], row["term"]] }
preflight_errors << "schema referenced detail rows must be unique by schema id and referenced term" unless schema_referenced_detail_keys == schema_referenced_detail_keys.uniq

schema_referenced_details = schema_row_ids.to_h { |id| [id, {}] }
schema_referenced_detail_rows.each do |row|
  if schema_referenced_details.key?(row["id"])
    schema_referenced_details.fetch(row["id"])[row["term"]] = {
      "kind" => row["kind"],
      "source" => row["source"],
      "rules" => row["rules"]
    }
  else
    preflight_errors << "schema referenced detail row references unknown schema id #{row["id"]}"
  end
end
schema_profile_rows.each do |row|
  required_fields = schema_required_fields.fetch(row["id"], [])
  expected = StrictModeMetadata.schema_referenced_terms(row["summary"], required_fields).sort
  actual = schema_referenced_details.fetch(row["id"], {}).keys.sort
  preflight_errors << "schema referenced details must match computed referenced terms for #{row["id"]}" unless expected == actual
end

schema_structured_profile_ids = schema_structured_profile_rows.map { |row| row["id"] }
preflight_errors << "schema structured profile ids must be unique" unless schema_structured_profile_ids == schema_structured_profile_ids.uniq
preflight_errors << "schema structured profile ids must match schema registry ids" unless schema_structured_profile_ids.sort == schema_row_ids.sort
schema_field_detail_keys = schema_field_detail_rows.map { |row| [row["id"], row["profile"]] }
preflight_errors << "schema field detail rows must be unique by schema id and field profile" unless schema_field_detail_keys == schema_field_detail_keys.uniq

schema_field_details = schema_row_ids.to_h { |id| [id, {}] }
schema_field_detail_rows.each do |row|
  if schema_field_details.key?(row["id"])
    schema_field_details.fetch(row["id"])[row["profile"]] = {
      "shape" => row["shape"],
      "members" => row["members"],
      "rules" => row["rules"]
    }
  else
    preflight_errors << "schema field detail row references unknown schema id #{row["id"]}"
  end
end
schema_structured_profile_rows.each do |row|
  expected = row["field_profiles"].sort
  actual = schema_field_details.fetch(row["id"], {}).keys.sort
  preflight_errors << "schema field details must match structured field profiles for #{row["id"]}" unless expected == actual
end

schema_enum_value_keys = schema_enum_value_rows.map { |row| [row["id"], row["family"]] }
preflight_errors << "schema enum value rows must be unique by schema id and enum family" unless schema_enum_value_keys == schema_enum_value_keys.uniq

schema_enum_values = schema_row_ids.to_h { |id| [id, {}] }
schema_enum_value_rows.each do |row|
  if schema_enum_values.key?(row["id"])
    schema_enum_values.fetch(row["id"])[row["family"]] = row["values"]
  else
    preflight_errors << "schema enum value row references unknown schema id #{row["id"]}"
  end
end
schema_structured_profile_rows.each do |row|
  expected = row["enum_families"].sort
  actual = schema_enum_values.fetch(row["id"], {}).keys.sort
  preflight_errors << "schema enum value families must match structured enum families for #{row["id"]}" unless expected == actual
end

schema_variant_rule_keys = schema_variant_rule_rows.map { |row| [row["id"], row["rule"]] }
preflight_errors << "schema variant rule rows must be unique by schema id and rule" unless schema_variant_rule_keys == schema_variant_rule_keys.uniq

schema_variant_rules = schema_row_ids.to_h { |id| [id, {}] }
schema_variant_rule_rows.each do |row|
  if schema_variant_rules.key?(row["id"])
    schema_variant_rules.fetch(row["id"])[row["rule"]] = {
      "selectors" => row["selectors"],
      "requires" => row["requires"],
      "forbids" => row["forbids"]
    }
  else
    preflight_errors << "schema variant rule row references unknown schema id #{row["id"]}"
  end
end
schema_structured_profile_rows.each do |row|
  expected = row["variant_requirements"].sort
  actual = schema_variant_rules.fetch(row["id"], {}).keys.sort
  preflight_errors << "schema variant rule details must match structured variant requirements for #{row["id"]}" unless expected == actual
end

matrix_row_ids = matrix_rows.map { |row| row["id"] }
matrix_expansion_ids = matrix_expansion_rows.map { |row| row["id"] }
preflight_errors << "matrix registry ids must be unique" unless matrix_row_ids == matrix_row_ids.uniq
preflight_errors << "matrix expansion ids must be unique" unless matrix_expansion_ids == matrix_expansion_ids.uniq
preflight_errors << "matrix expansion ids must match matrix registry ids" unless matrix_expansion_ids.sort == matrix_row_ids.sort

unless preflight_errors.empty?
  preflight_errors.each { |error| warn "#{spec_path}: #{error}" }
  exit 1
end

schema_ids = schema_rows.map { |row| row["id"] }.sort
matrix_ids = matrix_rows.map { |row| row["id"] }.sort

begin
  outputs = []

  schema_registry = {
    "schema_version" => 1,
    "registry_kind" => "schema",
    "ids" => schema_ids,
    "generated_from_spec_hash" => spec_hash,
    "registry_hash" => ""
  }
  schema_registry["registry_hash"] = StrictModeMetadata.hash_record(schema_registry, "registry_hash")
  outputs << [root.join("schemas/schema-registry.json"), schema_registry]

  matrix_registry = {
    "schema_version" => 1,
    "registry_kind" => "matrix",
    "ids" => matrix_ids,
    "generated_from_spec_hash" => spec_hash,
    "registry_hash" => ""
  }
  matrix_registry["registry_hash"] = StrictModeMetadata.hash_record(matrix_registry, "registry_hash")
  outputs << [root.join("matrices/matrix-registry.json"), matrix_registry]

  schema_rows.each do |row|
    summary = schema_profiles.fetch(row["id"])
    required_fields = schema_required_fields.fetch(row["id"])
    structured_profile = schema_structured_profiles.fetch(row["id"])
    profile = {
      "schema_version" => 1,
      "schema_id" => row["id"],
      "owner" => row["owner"],
      "input_family" => row["input_family"],
      "hash_fields" => row["hash_fields"],
      "required_fields" => required_fields,
      "referenced_terms" => StrictModeMetadata.schema_referenced_terms(summary, required_fields),
      "referenced_details" => schema_referenced_details.fetch(row["id"]),
      "field_profiles" => structured_profile["field_profiles"],
      "field_details" => schema_field_details.fetch(row["id"]),
      "enum_families" => structured_profile["enum_families"],
      "enum_values" => schema_enum_values.fetch(row["id"]),
      "variant_requirements" => structured_profile["variant_requirements"],
      "variant_rules" => schema_variant_rules.fetch(row["id"]),
      "variants" => StrictModeMetadata.split_profile_text(summary),
      "variant_details" => StrictModeMetadata.schema_variant_details(summary),
      "nested_profiles" => StrictModeMetadata.nested_schema_terms(summary),
      "fixture_requirements" => [row["artifact"]],
      "profile_hash" => ""
    }
    profile["profile_hash"] = StrictModeMetadata.hash_record(profile, "profile_hash")
    outputs << [root.join("schemas/#{row["id"]}.schema.json"), profile]
  end

  matrix_rows.each do |row|
    expansion = matrix_expansions.fetch(row["id"])
    profile = {
      "schema_version" => 1,
      "matrix_id" => row["id"],
      "owner" => row["owner"],
      "dimensions" => expansion["dimensions"],
      "allowed_rows" => expansion["allowed"],
      "forbidden_row_classes" => expansion["forbidden"],
      "fixture_requirements" => [row["purpose"]],
      "profile_hash" => ""
    }
    profile["profile_hash"] = StrictModeMetadata.hash_record(profile, "profile_hash")
    outputs << [root.join("matrices/#{row["id"]}.matrix.json"), profile]
  end

  outputs.each { |path, _record| StrictModeMetadata.ensure_json_write_target!(path) }
  outputs.each { |path, record| StrictModeMetadata.write_json(path, record) }
rescue RuntimeError, SystemCallError => e
  warn "#{spec_path}: generation error: #{e.message}"
  exit 1
end
