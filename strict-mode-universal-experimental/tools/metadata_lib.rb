# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module StrictModeMetadata
  ROOT = Pathname.new(__dir__).parent.expand_path
  SCHEMA_REGISTRY_FIELDS = %w[schema_version registry_kind ids generated_from_spec_hash registry_hash].freeze
  SCHEMA_PROFILE_FIELDS = %w[
    schema_version schema_id owner input_family hash_fields required_fields
    referenced_terms referenced_details field_profiles field_details enum_families
    enum_values variant_requirements variant_rules variants variant_details
    nested_profiles fixture_requirements profile_hash
  ].freeze
  MATRIX_REGISTRY_FIELDS = SCHEMA_REGISTRY_FIELDS
  MATRIX_PROFILE_FIELDS = %w[
    schema_version matrix_id owner dimensions allowed_rows forbidden_row_classes
    fixture_requirements profile_hash
  ].freeze
  SCHEMA_ID_PATTERN = /\A(?!matrix[.])[a-z]+(?:[.][a-z0-9-]+)+[.]v1\z/
  MATRIX_ID_PATTERN = /\Amatrix(?:[.][a-z0-9-]+)+[.]v1\z/

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  module_function

  def project_root
    ROOT
  end

  def spec_path(root = ROOT)
    Pathname.new(root).expand_path.join("specs/17-implementation-readiness.md")
  end

  def readme_path(root = ROOT)
    Pathname.new(root).expand_path.join("README.md")
  end

  def spec_text(root = ROOT)
    spec_path(root).read
  end

  def spec_hash(root = ROOT)
    Digest::SHA256.hexdigest(spec_path(root).binread)
  end

  def read_json_no_duplicates(path)
    JSON.parse(File.read(path), object_class: DuplicateKeyHash)
  end

  def canonical_json(value)
    case value
    when Hash
      "{" + value.keys.sort.map { |key| "#{canonical_json(key)}:#{canonical_json(value.fetch(key))}" }.join(",") + "}"
    when Array
      "[" + value.map { |item| canonical_json(item) }.join(",") + "]"
    when String
      JSON.generate(value)
    when Integer
      value.to_s
    when true
      "true"
    when false
      "false"
    when nil
      "null"
    else
      raise ArgumentError, "unsupported canonical JSON value: #{value.class}"
    end
  end

  def hash_record(record, hash_field)
    copy = deep_copy(record)
    copy[hash_field] = ""
    Digest::SHA256.hexdigest(canonical_json(copy))
  end

  def deep_copy(value)
    case value
    when Hash
      value.transform_values { |item| deep_copy(item) }
    when Array
      value.map { |item| deep_copy(item) }
    else
      value
    end
  end

  def split_sections(markdown)
    markdown.split(/^## /)
  end

  def section(markdown, heading)
    split_sections(markdown).find { |part| part.lines.first&.chomp == heading } || raise("section not found: #{heading}")
  end

  def subsection(markdown, heading)
    markdown.split(/^### /).find { |part| part.lines.first&.chomp == heading } || raise("subsection not found: #{heading}")
  end

  def table_rows(markdown)
    markdown.lines.each_with_object([]) do |line, rows|
      next unless line.start_with?("|")

      cells = split_markdown_table_row(line)
      next if cells.empty? || cells[0].start_with?("---") || ["Schema id", "Matrix id"].include?(cells[0])

      rows << cells
    end
  end

  def expect_cell_count!(cells, count, context)
    return if cells.length == count

    row_name = cells.first || "<empty row>"
    raise "#{context}: malformed table row #{row_name.inspect}: expected #{count} columns, got #{cells.length}"
  end

  def expect_no_empty_cells!(cells, context)
    return unless cells.any?(&:empty?)

    row_name = cells.first || "<empty row>"
    raise "#{context}: malformed table row #{row_name.inspect}: empty table cell"
  end

  def split_markdown_table_row(line)
    cells = []
    current = +""
    in_code = false
    line.strip.each_char.with_index do |char, index|
      if char == "`"
        in_code = !in_code
        current << char
      elsif char == "|" && !in_code
        cells << current.strip unless index.zero?
        current = +""
      else
        current << char
      end
    end
    cells
  end

  def code_cell_id(cell)
    match = cell.match(/\A`([^`]+)`\z/)
    match && match[1]
  end

  def code_cell_id!(cell, context, pattern, label)
    id = code_cell_id(cell) || raise("#{context}: malformed table row #{cell.inspect}: id cell must be backtick-wrapped")
    raise "#{context}: invalid #{label} #{id.inspect}" unless id.match?(pattern)

    id
  end

  def schema_registry_rows(markdown = spec_text)
    section_text = section(markdown, "17.1 Schema Registry")
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 5, "17.1 Schema Registry")
      expect_no_empty_cells!(cells, "17.1 Schema Registry")
      id = code_cell_id!(cells[0], "17.1 Schema Registry", SCHEMA_ID_PATTERN, "schema id")

      rows << {
        "id" => id,
        "owner" => cells[1],
        "input_family" => cells[2],
        "hash_fields" => parse_hash_fields(cells[3], "17.1 Schema Registry"),
        "artifact" => cells[4]
      }
    end
  end

  def schema_profile_rows(markdown = spec_text)
    section_text = section(markdown, "17.2 Schema Implementation Profiles").split(/^### /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 2, "17.2 Schema Implementation Profiles")
      expect_no_empty_cells!(cells, "17.2 Schema Implementation Profiles")
      id = code_cell_id!(cells[0], "17.2 Schema Implementation Profiles", SCHEMA_ID_PATTERN, "schema id")

      rows << {
        "id" => id,
        "summary" => cells[1]
      }
    end
  end

  def schema_required_field_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.2.1 Schema Required Field Lists").split(/^## /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 2, "17.2.1 Schema Required Field Lists")
      expect_no_empty_cells!(cells, "17.2.1 Schema Required Field Lists")
      id = code_cell_id!(cells[0], "17.2.1 Schema Required Field Lists", SCHEMA_ID_PATTERN, "schema id")

      rows << {
        "id" => id,
        "required_fields" => parse_required_fields(cells[1], "17.2.1 Schema Required Field Lists")
      }
    end
  end

  def schema_structured_profile_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.2.2 Schema Structured Profile Details").split(/^## /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 4, "17.2.2 Schema Structured Profile Details")
      expect_no_empty_cells!(cells, "17.2.2 Schema Structured Profile Details")
      id = code_cell_id!(cells[0], "17.2.2 Schema Structured Profile Details", SCHEMA_ID_PATTERN, "schema id")

      rows << {
        "id" => id,
        "field_profiles" => parse_profile_items(cells[1], "17.2.2 Schema Structured Profile Details"),
        "enum_families" => parse_profile_items(cells[2], "17.2.2 Schema Structured Profile Details"),
        "variant_requirements" => parse_profile_items(cells[3], "17.2.2 Schema Structured Profile Details")
      }
    end
  end

  def schema_referenced_detail_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.2.1.1 Schema Referenced Term Details").split(/^## /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 5, "17.2.1.1 Schema Referenced Term Details")
      expect_no_empty_cells!(cells, "17.2.1.1 Schema Referenced Term Details")
      id = code_cell_id!(cells[0], "17.2.1.1 Schema Referenced Term Details", SCHEMA_ID_PATTERN, "schema id")
      term = code_cell_id(cells[1]) || raise("17.2.1.1 Schema Referenced Term Details: malformed table row #{cells[1].inspect}: referenced term cell must be backtick-wrapped")
      kind = code_cell_id(cells[2]) || raise("17.2.1.1 Schema Referenced Term Details: malformed table row #{cells[2].inspect}: kind cell must be backtick-wrapped")
      source = code_cell_id(cells[3]) || raise("17.2.1.1 Schema Referenced Term Details: malformed table row #{cells[3].inspect}: source cell must be backtick-wrapped")

      rows << {
        "id" => id,
        "term" => term,
        "kind" => kind,
        "source" => source,
        "rules" => parse_profile_items(cells[4], "17.2.1.1 Schema Referenced Term Details")
      }
    end
  end

  def schema_enum_value_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.2.3 Schema Enum Values").split(/^## /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 3, "17.2.3 Schema Enum Values")
      expect_no_empty_cells!(cells, "17.2.3 Schema Enum Values")
      id = code_cell_id!(cells[0], "17.2.3 Schema Enum Values", SCHEMA_ID_PATTERN, "schema id")
      family = code_cell_id(cells[1]) || raise("17.2.3 Schema Enum Values: malformed table row #{cells[1].inspect}: enum family cell must be backtick-wrapped")

      rows << {
        "id" => id,
        "family" => family,
        "values" => parse_enum_values(cells[2], "17.2.3 Schema Enum Values")
      }
    end
  end

  def schema_field_detail_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.2.2.1 Schema Field Profile Details").split(/^## /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 5, "17.2.2.1 Schema Field Profile Details")
      expect_no_empty_cells!(cells, "17.2.2.1 Schema Field Profile Details")
      id = code_cell_id!(cells[0], "17.2.2.1 Schema Field Profile Details", SCHEMA_ID_PATTERN, "schema id")
      profile = code_cell_id(cells[1]) || raise("17.2.2.1 Schema Field Profile Details: malformed table row #{cells[1].inspect}: field profile cell must be backtick-wrapped")
      shape = code_cell_id(cells[2]) || raise("17.2.2.1 Schema Field Profile Details: malformed table row #{cells[2].inspect}: shape cell must be backtick-wrapped")

      rows << {
        "id" => id,
        "profile" => profile,
        "shape" => shape,
        "members" => parse_profile_items(cells[3], "17.2.2.1 Schema Field Profile Details"),
        "rules" => parse_profile_items(cells[4], "17.2.2.1 Schema Field Profile Details")
      }
    end
  end

  def schema_variant_rule_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.2.4 Schema Variant Rule Details").split(/^## /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 5, "17.2.4 Schema Variant Rule Details")
      expect_no_empty_cells!(cells, "17.2.4 Schema Variant Rule Details")
      id = code_cell_id!(cells[0], "17.2.4 Schema Variant Rule Details", SCHEMA_ID_PATTERN, "schema id")
      rule = code_cell_id(cells[1]) || raise("17.2.4 Schema Variant Rule Details: malformed table row #{cells[1].inspect}: variant rule cell must be backtick-wrapped")

      rows << {
        "id" => id,
        "rule" => rule,
        "selectors" => parse_profile_items(cells[2], "17.2.4 Schema Variant Rule Details"),
        "requires" => parse_profile_items(cells[3], "17.2.4 Schema Variant Rule Details"),
        "forbids" => parse_profile_items(cells[4], "17.2.4 Schema Variant Rule Details")
      }
    end
  end

  def matrix_registry_rows(markdown = spec_text)
    section_text = section(markdown, "17.4 Closed Matrix Registry").split(/^### /).first
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 4, "17.4 Closed Matrix Registry")
      expect_no_empty_cells!(cells, "17.4 Closed Matrix Registry")
      id = code_cell_id!(cells[0], "17.4 Closed Matrix Registry", MATRIX_ID_PATTERN, "matrix id")

      rows << {
        "id" => id,
        "owner" => cells[1],
        "purpose" => cells[2],
        "validator" => cells[3]
      }
    end
  end

  def matrix_expansion_rows(markdown = spec_text)
    section_text = subsection(markdown, "17.4.1 Matrix Expansion Requirements")
    table_rows(section_text).each_with_object([]) do |cells, rows|
      expect_cell_count!(cells, 4, "17.4.1 Matrix Expansion Requirements")
      expect_no_empty_cells!(cells, "17.4.1 Matrix Expansion Requirements")
      id = code_cell_id!(cells[0], "17.4.1 Matrix Expansion Requirements", MATRIX_ID_PATTERN, "matrix id")

      rows << {
        "id" => id,
        "dimensions" => split_profile_text(cells[1]),
        "allowed" => split_profile_text(cells[2]),
        "forbidden" => split_profile_text(cells[3])
      }
    end
  end

  def parse_hash_fields(cell, context)
    return [] if cell == "none"

    fields = []
    remainder = cell.gsub(/`([a-z][a-z0-9_]*)`/) do
      fields << Regexp.last_match(1)
      ""
    end
    remainder = remainder.gsub(/\bnested\b|\band\b|,|\s/, "")
    return fields if fields.any? && remainder.empty?

    raise "#{context}: malformed hash field cell #{cell.inspect}: expected none or backtick-wrapped field names"
  end

  def parse_required_fields(cell, context)
    return [] if cell == "none"

    fields = []
    remainder = cell.gsub(/`([a-z][a-z0-9_]*)`/) do
      fields << Regexp.last_match(1)
      ""
    end
    remainder = remainder.gsub(/\band\b|,|\s/, "")
    unless fields.any? && remainder.empty?
      raise "#{context}: malformed required field cell #{cell.inspect}: expected none or backtick-wrapped field names"
    end
    raise "#{context}: duplicate required field in #{cell.inspect}" unless fields == fields.uniq

    fields
  end

  def split_profile_text(text)
    text.split(/;\s+/).flat_map { |part| part.split(/\.\s+/) }.map(&:strip).reject(&:empty?)
  end

  def schema_variant_details(text)
    variants = split_profile_text(text)
    raise "duplicate implementation profile clause" unless variants == variants.uniq

    variants.each_with_index.to_h do |clause, index|
      normalized = strip_markdown_code(clause)
      [clause, {
        "index" => index + 1,
        "kind" => implementation_clause_kind(normalized),
        "source" => "17.2 Schema Implementation Profiles",
        "rules" => [normalized]
      }]
    end
  end

  def strip_markdown_code(text)
    text.gsub(/`([^`]+)`/, "\\1")
  end

  def implementation_clause_kind(clause)
    normalized = clause.downcase
    return "exact-fields" if normalized.start_with?("exact")
    return "filename-binding" if normalized.include?("filename")
    return "registry-kind" if normalized.include?("registry_kind")
    return "registry-id-set" if normalized.include?("sorted unique ids")
    return "hash-recompute" if normalized.include?("hash recomputation") || normalized.include?("hash recompute")
    return "matrix-binding" if normalized.include?("closed matrix validator")
    return "domain" if normalized.match?(/\b(enums?|domains?|directives?|actions?|kinds?|variants?|modes?|sources?)\b/)
    return "grammar" if normalized.match?(/\b(grammar|syntax|parser|bounds?|cap|line)\b/)
    return "nested-shape" if normalized.match?(/\b(nested|object|record|tuple|list|path|field|schema)\b/)
    return "fixture-proof" if normalized.match?(/\b(fixture|proof|contract|install baseline|generated command)\b/)
    return "negative-rule" if normalized.match?(/\b(no extra|rejection|refusal|forbidden|fail-closed|reject)\b/)

    "behavior"
  end

  def parse_profile_items(cell, context)
    return [] if cell == "none"

    items = split_profile_text(cell).map { |item| item.gsub(/`([^`]+)`/, "\\1") }
    raise "#{context}: malformed profile item cell #{cell.inspect}" if items.empty? || items.include?("none")
    raise "#{context}: duplicate profile item in #{cell.inspect}" unless items == items.uniq

    items
  end

  def parse_enum_values(cell, context)
    values = []
    remainder = cell.gsub(/`([^`]+)`/) do
      values << Regexp.last_match(1)
      ""
    end
    remainder = remainder.gsub(/\band\b|,|\s/, "")
    unless values.any? && remainder.empty?
      raise "#{context}: malformed enum value cell #{cell.inspect}: expected backtick-wrapped values"
    end
    raise "#{context}: duplicate enum value in #{cell.inspect}" unless values == values.uniq

    values
  end

  def backtick_terms(text)
    text.scan(/`([^`]+)`/).flatten.uniq
  end

  def nested_schema_terms(text)
    backtick_terms(text).grep(SCHEMA_ID_PATTERN)
  end

  def schema_referenced_terms(text, required_fields)
    backtick_terms(text).reject { |term| required_fields.include?(term) }.uniq
  end

  def ensure_json_write_target!(path)
    path = Pathname.new(path)
    parent = path.dirname
    raise "#{path}: parent path is not a directory" if parent.exist? && !parent.directory?
    raise "#{path}: target path is not a file" if path.exist? && !path.file?
  end

  def write_json(path, record)
    path = Pathname.new(path)
    path.dirname.mkpath
    path.write(JSON.pretty_generate(record) + "\n")
  rescue SystemCallError => e
    raise "#{path}: cannot write: #{e.message}"
  end
end
