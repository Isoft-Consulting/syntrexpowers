#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "metadata_lib"

class MetadataValidator
  include StrictModeMetadata
  INVALID_RECORD = Object.new.freeze

  def initialize(root: StrictModeMetadata.project_root)
    @errors = []
    @root = Pathname.new(root).expand_path
    @schema_rows = []
    @schema_profile_rows = []
    @schema_profiles = {}
    @schema_required_field_rows = []
    @schema_required_fields = {}
    @schema_referenced_detail_rows = []
    @schema_referenced_details = {}
    @schema_structured_profile_rows = []
    @schema_structured_profiles = {}
    @schema_field_detail_rows = []
    @schema_field_details = {}
    @schema_enum_value_rows = []
    @schema_enum_values = {}
    @schema_variant_rule_rows = []
    @schema_variant_rules = {}
    @matrix_rows = []
    @matrix_expansion_rows = []
    @matrix_expansions = {}
    @spec_ready = false
    load_spec_context
  end

  def run
    return report unless @spec_ready

    validate_spec_metadata_parity
    validate_registry("schema")
    validate_registry("matrix")
    validate_schema_profiles
    validate_matrix_profiles
    validate_readme_provider_matrix_mapping
    validate_no_extra_profiles
    report
  end

  private

  def load_spec_context
    spec_path = StrictModeMetadata.spec_path(@root)
    unless spec_path.exist?
      @errors << "#{spec_path}: missing"
      return
    end
    unless spec_path.file?
      @errors << "#{spec_path}: not a file"
      return
    end

    @spec_text = spec_path.read
    @spec_hash = Digest::SHA256.hexdigest(spec_path.binread)
    @schema_rows = StrictModeMetadata.schema_registry_rows(@spec_text)
    @schema_profile_rows = StrictModeMetadata.schema_profile_rows(@spec_text)
    @schema_profiles = @schema_profile_rows.to_h { |row| [row["id"], row["summary"]] }
    @schema_required_field_rows = StrictModeMetadata.schema_required_field_rows(@spec_text)
    @schema_required_fields = @schema_required_field_rows.to_h { |row| [row["id"], row["required_fields"]] }
    @schema_referenced_detail_rows = StrictModeMetadata.schema_referenced_detail_rows(@spec_text)
    @schema_referenced_details = @schema_rows.map { |row| [row["id"], {}] }.to_h
    @schema_referenced_detail_rows.each do |row|
      @schema_referenced_details[row["id"]] ||= {}
      @schema_referenced_details.fetch(row["id"])[row["term"]] = {
        "kind" => row["kind"],
        "source" => row["source"],
        "rules" => row["rules"]
      }
    end
    @schema_structured_profile_rows = StrictModeMetadata.schema_structured_profile_rows(@spec_text)
    @schema_structured_profiles = @schema_structured_profile_rows.to_h { |row| [row["id"], row] }
    @schema_field_detail_rows = StrictModeMetadata.schema_field_detail_rows(@spec_text)
    @schema_field_details = @schema_rows.map { |row| [row["id"], {}] }.to_h
    @schema_field_detail_rows.each do |row|
      @schema_field_details[row["id"]] ||= {}
      @schema_field_details.fetch(row["id"])[row["profile"]] = {
        "shape" => row["shape"],
        "members" => row["members"],
        "rules" => row["rules"]
      }
    end
    @schema_enum_value_rows = StrictModeMetadata.schema_enum_value_rows(@spec_text)
    @schema_enum_values = @schema_rows.map { |row| [row["id"], {}] }.to_h
    @schema_enum_value_rows.each do |row|
      @schema_enum_values[row["id"]] ||= {}
      @schema_enum_values.fetch(row["id"])[row["family"]] = row["values"]
    end
    @schema_variant_rule_rows = StrictModeMetadata.schema_variant_rule_rows(@spec_text)
    @schema_variant_rules = @schema_rows.map { |row| [row["id"], {}] }.to_h
    @schema_variant_rule_rows.each do |row|
      @schema_variant_rules[row["id"]] ||= {}
      @schema_variant_rules.fetch(row["id"])[row["rule"]] = {
        "selectors" => row["selectors"],
        "requires" => row["requires"],
        "forbids" => row["forbids"]
      }
    end
    @matrix_rows = StrictModeMetadata.matrix_registry_rows(@spec_text)
    @matrix_expansion_rows = StrictModeMetadata.matrix_expansion_rows(@spec_text)
    @matrix_expansions = @matrix_expansion_rows.to_h { |row| [row["id"], row] }
    @spec_ready = true
  rescue SystemCallError, RuntimeError => e
    @errors << "#{spec_path}: spec parse error: #{e.message}"
  end

  def validate_spec_metadata_parity
    schema_ids = @schema_rows.map { |row| row["id"] }
    expect(StrictModeMetadata.spec_path(@root), schema_ids == schema_ids.uniq, "schema registry ids must be unique")
    schema_profile_ids = @schema_profile_rows.map { |row| row["id"] }
    expect(StrictModeMetadata.spec_path(@root), schema_profile_ids == schema_profile_ids.uniq, "schema implementation profile ids must be unique")
    expect(StrictModeMetadata.spec_path(@root), schema_profile_ids.sort == schema_ids.sort, "schema implementation profile ids must match schema registry ids")
    @schema_profile_rows.each do |row|
      clauses = StrictModeMetadata.split_profile_text(row["summary"])
      expect(StrictModeMetadata.spec_path(@root), clauses == clauses.uniq, "schema implementation profile clauses must be unique for #{row["id"]}")
    end
    schema_required_field_ids = @schema_required_field_rows.map { |row| row["id"] }
    expect(StrictModeMetadata.spec_path(@root), schema_required_field_ids == schema_required_field_ids.uniq, "schema required field list ids must be unique")
    expect(StrictModeMetadata.spec_path(@root), schema_required_field_ids.sort == schema_ids.sort, "schema required field list ids must match schema registry ids")
    schema_referenced_detail_keys = @schema_referenced_detail_rows.map { |row| [row["id"], row["term"]] }
    expect(StrictModeMetadata.spec_path(@root), schema_referenced_detail_keys == schema_referenced_detail_keys.uniq, "schema referenced detail rows must be unique by schema id and referenced term")
    unknown_referenced_detail_schema_ids = @schema_referenced_detail_rows.map { |row| row["id"] }.uniq - schema_ids
    unknown_referenced_detail_schema_ids.each do |id|
      expect(StrictModeMetadata.spec_path(@root), false, "schema referenced detail row references unknown schema id #{id}")
    end
    @schema_profile_rows.each do |row|
      required_fields = @schema_required_fields.fetch(row["id"], [])
      expected = StrictModeMetadata.schema_referenced_terms(row["summary"], required_fields).sort
      actual = @schema_referenced_details.fetch(row["id"], {}).keys.sort
      expect(StrictModeMetadata.spec_path(@root), expected == actual, "schema referenced details must match computed referenced terms for #{row["id"]}")
    end

    schema_structured_profile_ids = @schema_structured_profile_rows.map { |row| row["id"] }
    expect(StrictModeMetadata.spec_path(@root), schema_structured_profile_ids == schema_structured_profile_ids.uniq, "schema structured profile ids must be unique")
    expect(StrictModeMetadata.spec_path(@root), schema_structured_profile_ids.sort == schema_ids.sort, "schema structured profile ids must match schema registry ids")
    schema_field_detail_keys = @schema_field_detail_rows.map { |row| [row["id"], row["profile"]] }
    expect(StrictModeMetadata.spec_path(@root), schema_field_detail_keys == schema_field_detail_keys.uniq, "schema field detail rows must be unique by schema id and field profile")
    unknown_field_detail_schema_ids = @schema_field_detail_rows.map { |row| row["id"] }.uniq - schema_ids
    unknown_field_detail_schema_ids.each do |id|
      expect(StrictModeMetadata.spec_path(@root), false, "schema field detail row references unknown schema id #{id}")
    end
    @schema_structured_profile_rows.each do |row|
      expected = row["field_profiles"].sort
      actual = @schema_field_details.fetch(row["id"], {}).keys.sort
      expect(StrictModeMetadata.spec_path(@root), expected == actual, "schema field details must match structured field profiles for #{row["id"]}")
    end
    schema_enum_value_keys = @schema_enum_value_rows.map { |row| [row["id"], row["family"]] }
    expect(StrictModeMetadata.spec_path(@root), schema_enum_value_keys == schema_enum_value_keys.uniq, "schema enum value rows must be unique by schema id and enum family")
    unknown_enum_schema_ids = @schema_enum_value_rows.map { |row| row["id"] }.uniq - schema_ids
    unknown_enum_schema_ids.each do |id|
      expect(StrictModeMetadata.spec_path(@root), false, "schema enum value row references unknown schema id #{id}")
    end
    @schema_structured_profile_rows.each do |row|
      expected = row["enum_families"].sort
      actual = @schema_enum_values.fetch(row["id"], {}).keys.sort
      expect(StrictModeMetadata.spec_path(@root), expected == actual, "schema enum value families must match structured enum families for #{row["id"]}")
    end
    schema_variant_rule_keys = @schema_variant_rule_rows.map { |row| [row["id"], row["rule"]] }
    expect(StrictModeMetadata.spec_path(@root), schema_variant_rule_keys == schema_variant_rule_keys.uniq, "schema variant rule rows must be unique by schema id and rule")
    unknown_variant_schema_ids = @schema_variant_rule_rows.map { |row| row["id"] }.uniq - schema_ids
    unknown_variant_schema_ids.each do |id|
      expect(StrictModeMetadata.spec_path(@root), false, "schema variant rule row references unknown schema id #{id}")
    end
    @schema_structured_profile_rows.each do |row|
      expected = row["variant_requirements"].sort
      actual = @schema_variant_rules.fetch(row["id"], {}).keys.sort
      expect(StrictModeMetadata.spec_path(@root), expected == actual, "schema variant rule details must match structured variant requirements for #{row["id"]}")
    end

    matrix_ids = @matrix_rows.map { |row| row["id"] }
    expect(StrictModeMetadata.spec_path(@root), matrix_ids == matrix_ids.uniq, "matrix registry ids must be unique")
    matrix_expansion_ids = @matrix_expansion_rows.map { |row| row["id"] }
    expect(StrictModeMetadata.spec_path(@root), matrix_expansion_ids == matrix_expansion_ids.uniq, "matrix expansion ids must be unique")
    expect(StrictModeMetadata.spec_path(@root), matrix_expansion_ids.sort == matrix_ids.sort, "matrix expansion ids must match matrix registry ids")
  end

  def validate_registry(kind)
    expected_ids = kind == "schema" ? @schema_rows.map { |row| row["id"] }.sort : @matrix_rows.map { |row| row["id"] }.sort
    path = @root.join("#{kind == "schema" ? "schemas" : "matrices"}/#{kind}-registry.json")
    record = read_record(path)
    return if record.equal?(INVALID_RECORD)

    return unless expect_exact_fields(path, record, StrictModeMetadata::SCHEMA_REGISTRY_FIELDS)

    ids = record["ids"]
    expect(path, record["schema_version"] == 1, "schema_version must be 1")
    expect(path, record["registry_kind"] == kind, "registry_kind must be #{kind.inspect}")
    expect(path, array_of_strings?(ids), "ids must be an array of strings")
    if array_of_strings?(ids)
      expect(path, ids == ids.uniq.sort, "ids must be sorted and unique")
      expect(path, ids == expected_ids, "ids must match markdown #{kind} registry")
    end
    expect(path, record["generated_from_spec_hash"] == @spec_hash, "generated_from_spec_hash must match specs/17-implementation-readiness.md")
    expect_hash(path, record, "registry_hash")
  end

  def validate_schema_profiles
    registry = @schema_rows.to_h { |row| [row["id"], row] }
    registry.each do |id, row|
      path = @root.join("schemas/#{id}.schema.json")
      record = read_record(path)
      next if record.equal?(INVALID_RECORD)

      next unless expect_exact_fields(path, record, StrictModeMetadata::SCHEMA_PROFILE_FIELDS)

      expect(path, record["schema_version"] == 1, "schema_version must be 1")
      expect(path, record["schema_id"] == id, "schema_id must match filename")
      expect(path, record["owner"] == row["owner"], "owner must match markdown registry")
      expect(path, record["input_family"] == row["input_family"], "input_family must match markdown registry")
      expect(path, record["hash_fields"] == row["hash_fields"], "hash_fields must match markdown registry")
      %w[required_fields referenced_terms field_profiles enum_families variant_requirements variants nested_profiles fixture_requirements].each do |field|
        expect(path, array_of_strings?(record[field]), "#{field} must be an array of strings")
      end
      expect(path, referenced_details_object?(record["referenced_details"]), "referenced_details must be an object mapping referenced terms to kind/source/rule details")
      expect(path, field_details_object?(record["field_details"]), "field_details must be an object mapping field profiles to shape/member/rule details")
      expect(path, enum_values_object?(record["enum_values"]), "enum_values must be an object mapping enum families to arrays of strings")
      expect(path, variant_rules_object?(record["variant_rules"]), "variant_rules must be an object mapping rules to selector/require/forbid arrays")
      expect(path, variant_details_object?(record["variant_details"]), "variant_details must be an object mapping implementation clauses to index/kind/source/rule details")
      summary = @schema_profiles[id]
      if summary
        required_fields = @schema_required_fields.fetch(id, [])
        variants = StrictModeMetadata.split_profile_text(summary)
        referenced_details = @schema_referenced_details.fetch(id, {})
        structured_profile = @schema_structured_profiles.fetch(id, {})
        field_details = @schema_field_details.fetch(id, {})
        enum_values = @schema_enum_values.fetch(id, {})
        variant_rules = @schema_variant_rules.fetch(id, {})
        expect(path, record["required_fields"] == required_fields, "required_fields must match markdown required field list")
        expect(path, record["referenced_terms"] == StrictModeMetadata.schema_referenced_terms(summary, required_fields), "referenced_terms must match markdown implementation profile")
        expect(path, record["referenced_details"] == referenced_details, "referenced_details must match markdown referenced term detail table")
        expect(path, record["field_profiles"] == structured_profile["field_profiles"], "field_profiles must match markdown structured profile")
        expect(path, record["field_details"] == field_details, "field_details must match markdown field detail table")
        expect(path, record["enum_families"] == structured_profile["enum_families"], "enum_families must match markdown structured profile")
        expect(path, record["enum_values"] == enum_values, "enum_values must match markdown enum value table")
        expect(path, record["variant_requirements"] == structured_profile["variant_requirements"], "variant_requirements must match markdown structured profile")
        expect(path, record["variant_rules"] == variant_rules, "variant_rules must match markdown variant rule table")
        expect(path, record["variants"] == variants, "variants must match markdown implementation profile")
        if variants == variants.uniq
          expect(path, record["variant_details"] == StrictModeMetadata.schema_variant_details(summary), "variant_details must match markdown implementation profile clause details")
        end
        expect(path, record["nested_profiles"] == StrictModeMetadata.nested_schema_terms(summary), "nested_profiles must match markdown implementation profile")
      end
      expect(path, array_of_strings?(record["variants"]) && !record["variants"].empty?, "variants must encode the implementation profile prose")
      expect(path, record["fixture_requirements"] == [row["artifact"]], "fixture_requirements must bind required implementation artifact")
      expect_hash(path, record, "profile_hash")
    end
  end

  def validate_matrix_profiles
    registry = @matrix_rows.to_h { |row| [row["id"], row] }
    registry.each do |id, row|
      path = @root.join("matrices/#{id}.matrix.json")
      record = read_record(path)
      next if record.equal?(INVALID_RECORD)

      next unless expect_exact_fields(path, record, StrictModeMetadata::MATRIX_PROFILE_FIELDS)

      expansion = @matrix_expansions[id]
      unless expansion
        expect(path, false, "matrix expansion missing in specs/17-implementation-readiness.md")
        next
      end

      expect(path, record["schema_version"] == 1, "schema_version must be 1")
      expect(path, record["matrix_id"] == id, "matrix_id must match filename")
      expect(path, record["owner"] == row["owner"], "owner must match markdown registry")
      expect(path, record["dimensions"] == expansion["dimensions"], "dimensions must match markdown expansion requirements")
      expect(path, record["allowed_rows"] == expansion["allowed"], "allowed_rows must match markdown expansion requirements")
      expect(path, record["forbidden_row_classes"] == expansion["forbidden"], "forbidden_row_classes must match markdown expansion requirements")
      expect(path, record["fixture_requirements"] == [row["purpose"]], "fixture_requirements must bind matrix purpose")
      %w[dimensions allowed_rows forbidden_row_classes fixture_requirements].each do |field|
        expect(path, array_of_strings?(record[field]), "#{field} must be an array of strings")
      end
      expect_hash(path, record, "profile_hash")
    end
  end

  def validate_no_extra_profiles
    expected_schema_files = @schema_rows.map { |row| "schemas/#{row["id"]}.schema.json" }.sort
    actual_schema_files = Dir[@root.join("schemas/*.schema.json")].map do |path|
      Pathname.new(path).relative_path_from(@root).to_s
    end.sort
    expect(@root.join("schemas"), actual_schema_files == expected_schema_files, "schema profile file set must match registry")

    expected_matrix_files = @matrix_rows.map { |row| "matrices/#{row["id"]}.matrix.json" }.sort
    actual_matrix_files = Dir[@root.join("matrices/*.matrix.json")].map do |path|
      Pathname.new(path).relative_path_from(@root).to_s
    end.sort
    expect(@root.join("matrices"), actual_matrix_files == expected_matrix_files, "matrix profile file set must match registry")
  end

  def validate_readme_provider_matrix_mapping
    readme_path = StrictModeMetadata.readme_path(@root)
    unless readme_path.exist?
      @errors << "#{readme_path}: missing"
      return
    end
    unless readme_path.file?
      @errors << "#{readme_path}: not a file"
      return
    end

    readme_text = readme_path.read
    readme_section = StrictModeMetadata.section(readme_text, "Provider Support Matrix")
    readme_rows = readme_provider_rows(readme_section, readme_path)
    expect(readme_path, !readme_rows.empty?, "README provider matrix must contain rows")
    mapping = provider_feature_readme_mapping

    status_values = readme_rows.flat_map { |row| [row[1], row[2]] }.uniq
    proof_values = readme_rows.map { |row| row[3] }.uniq
    capability_values = readme_rows.map(&:first)
    expect(readme_path, capability_values == mapping.fetch("capability"), "README provider capability rows must match 17.4.2")
    (status_values - mapping.fetch("status")).each do |value|
      expect(readme_path, false, "README provider status cell is not mapped in 17.4.2: #{value.inspect}")
    end
    (proof_values - mapping.fetch("proof")).each do |value|
      expect(readme_path, false, "README provider proof cell is not mapped in 17.4.2: #{value.inspect}")
    end
  rescue SystemCallError, RuntimeError => e
    @errors << "#{readme_path}: README provider matrix parse error: #{e.message}"
  end

  def readme_provider_rows(section_text, readme_path)
    expected_header = ["Capability", "Claude Code", "Codex CLI", "Required proof before enforcement"]
    header_seen = false
    capabilities = []
    rows = []
    section_text.lines.each do |line|
      next unless line.start_with?("|")

      cells = StrictModeMetadata.split_markdown_table_row(line)
      next if cells.empty? || cells[0].start_with?("---")
      if cells[0] == "Capability"
        header_seen = true
        expect(readme_path, cells == expected_header, "README provider matrix header must match #{expected_header.inspect}")
        next
      end

      expect(readme_path, cells.length == 4, "README provider matrix row must have 4 columns")
      expect(readme_path, !cells.any?(&:empty?), "README provider matrix row must not contain empty cells")
      next unless cells.length == 4 && !cells.any?(&:empty?)

      capabilities << cells[0]
      rows << cells
    end
    expect(readme_path, header_seen, "README provider matrix header is missing")
    expect(readme_path, capabilities == capabilities.uniq, "README provider matrix capabilities must be unique")
    rows
  end

  def provider_feature_readme_mapping
    mapping_section = StrictModeMetadata.subsection(@spec_text, "17.4.2 Provider Feature README Status And Proof Mapping")
    status_text, proof_and_tail = mapping_section.split("The provider-feature matrix also owns exact mappings for the `Required proof before enforcement` cells", 2)
    raise "provider proof mapping block not found" unless proof_and_tail

    proof_text, capability_and_tail = proof_and_tail.split("The provider-feature matrix also owns exact capability cells", 2)
    raise "provider capability mapping block not found" unless capability_and_tail

    capability_text = capability_and_tail.split("README exact status or proof text", 2).first
    {
      "status" => status_text.scan(/"([^"]+)"/).flatten,
      "proof" => proof_text.scan(/"([^"]+)"/).flatten,
      "capability" => capability_text.scan(/"([^"]+)"/).flatten
    }
  end

  def read_record(path)
    unless path.exist?
      @errors << "#{path}: missing"
      return INVALID_RECORD
    end

    StrictModeMetadata.read_json_no_duplicates(path)
  rescue JSON::ParserError => e
    @errors << "#{path}: invalid JSON: #{e.message}"
    INVALID_RECORD
  rescue SystemCallError => e
    @errors << "#{path}: cannot read: #{e.message}"
    INVALID_RECORD
  end

  def expect_exact_fields(path, record, fields)
    expect(path, record.is_a?(Hash), "record must be a JSON object")
    return false unless record.is_a?(Hash)

    extra = record.keys - fields
    missing = fields - record.keys
    expect(path, extra.empty?, "extra fields: #{extra.join(", ")}")
    expect(path, missing.empty?, "missing fields: #{missing.join(", ")}")
    true
  end

  def expect_hash(path, record, field)
    value = record[field]
    expect(path, value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/), "#{field} must be lowercase SHA-256")
    return unless value.is_a?(String)

    expected = StrictModeMetadata.hash_record(record, field)
    expect(path, value == expected, "#{field} mismatch")
  rescue ArgumentError => e
    @errors << "#{path}: #{field} cannot be recomputed: #{e.message}"
  end

  def expect(path, condition, message)
    @errors << "#{path}: #{message}" unless condition
  end

  def array_of_strings?(value)
    value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
  end

  def enum_values_object?(value)
    value.is_a?(Hash) && value.all? { |key, item| key.is_a?(String) && array_of_strings?(item) }
  end

  def referenced_details_object?(value)
    value.is_a?(Hash) && value.all? do |key, item|
      key.is_a?(String) &&
        item.is_a?(Hash) &&
        item.keys.sort == %w[kind rules source] &&
        item["kind"].is_a?(String) &&
        item["source"].is_a?(String) &&
        array_of_strings?(item["rules"])
    end
  end

  def field_details_object?(value)
    value.is_a?(Hash) && value.all? do |key, item|
      key.is_a?(String) &&
        item.is_a?(Hash) &&
        item.keys.sort == %w[members rules shape] &&
        item["shape"].is_a?(String) &&
        array_of_strings?(item["members"]) &&
        array_of_strings?(item["rules"])
    end
  end

  def variant_rules_object?(value)
    value.is_a?(Hash) && value.all? do |key, item|
      key.is_a?(String) &&
        item.is_a?(Hash) &&
        item.keys.sort == %w[forbids requires selectors] &&
        array_of_strings?(item["selectors"]) &&
        array_of_strings?(item["requires"]) &&
        array_of_strings?(item["forbids"])
    end
  end

  def variant_details_object?(value)
    value.is_a?(Hash) && value.all? do |key, item|
      key.is_a?(String) &&
        item.is_a?(Hash) &&
        item.keys.sort == %w[index kind rules source] &&
        item["index"].is_a?(Integer) &&
        item["index"].positive? &&
        item["kind"].is_a?(String) &&
        item["source"].is_a?(String) &&
        array_of_strings?(item["rules"]) &&
        !item["rules"].empty?
    end
  end

  def report
    if @errors.empty?
      puts "metadata validation passed"
      return 0
    end

    @errors.each { |error| warn error }
    1
  end
end

options = { root: StrictModeMetadata.project_root }
parser = OptionParser.new do |option_parser|
  option_parser.banner = "Usage: validate-metadata.rb [--root PATH]"
  option_parser.on("--root PATH", "Validate metadata rooted at PATH") do |root|
    options[:root] = root
  end
end

begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
  exit 2
end

exit MetadataValidator.new(root: options.fetch(:root)).run
