#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require_relative "fixture_readiness_lib"
require_relative "hook_entry_plan_lib"
require_relative "metadata_lib"
require_relative "protected_config_lib"

module StrictModeProtectedBaseline
  extend self

  ZERO_HASH = "0" * 64
  CONFIG_KINDS = {
    "runtime.env" => "runtime-env",
    "protected-paths.txt" => "protected-paths",
    "filesystem-read-allowlist.txt" => "filesystem-read-allowlist",
    "network-allowlist.txt" => "network-allowlist",
    "destructive-patterns.txt" => "destructive-patterns",
    "stub-allowlist.txt" => "stub-allowlist"
  }.freeze
  EXPECTED_GENERATED_HOOK_ENV = { "STRICT_HOOK_TIMEOUT_MS" => "per-hook command prefix" }.freeze
  FILE_RECORD_KINDS = %w[
    runtime-file
    runtime-config
    provider-config
    protected-config
    fixture-manifest
    install-manifest
  ].freeze
  INODE_INDEX_ENTRY_FIELDS = %w[content_sha256 dev inode kind path provider].freeze
  FIXTURE_MANIFEST_RECORD_FIELDS = %w[
    contract_id
    contract_kind
    event
    fixture_manifest_hash
    fixture_record_hash
    platform
    provider
    provider_build_hash
    provider_version
  ].freeze
  FILE_RECORD_FIELDS = %w[
    content_sha256
    dev
    exists
    inode
    kind
    mode
    owner_uid
    path
    provider
    realpath
    size_bytes
  ].freeze
  MANIFEST_FIELDS = %w[
    active_runtime_link
    active_runtime_target
    config_root
    created_at
    fixture_manifest_records
    install_root
    managed_hook_entries
    manifest_hash
    package_version
    protected_config_records
    provider_config_records
    runtime_config_records
    runtime_file_records
    selected_output_contracts
    schema_version
    state_root
    transaction_id
    updated_at
  ].freeze
  BASELINE_FIELDS = %w[
    active_runtime_link
    active_runtime_target
    baseline_hash
    config_root
    created_at
    fixture_manifest_records
    generated_hook_commands
    generated_hook_env
    install_manifest_hash
    install_root
    kind
    managed_hook_entries
    package_version
    protected_config_records
    protected_file_inode_index
    provider_config_paths
    provider_config_records
    runtime_config_records
    runtime_file_records
    schema_version
    selected_output_contracts
    state_root
    transaction_id
    updated_at
  ].freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def load(install_root:, state_root: nil, project_dir: nil, home: Dir.home)
    errors = []
    config_errors = []
    install_path = normalize_absolute(install_root, "install_root", errors)
    state_path = normalize_absolute(state_root || install_path.join("state"), "state_root", errors)
    project_path = project_dir ? normalize_absolute(project_dir, "project_dir", errors) : nil
    home_path = normalize_absolute(home, "home", errors)

    return result(false, errors, config_errors) unless errors.empty?

    manifest_path = install_path.join("install-manifest.json")
    baseline_path = state_path.join("protected-install-baseline.json")
    manifest = load_json(manifest_path, errors)
    baseline = load_json(baseline_path, errors)
    return result(false, errors, config_errors) unless manifest && baseline

    verify_hash(manifest, "manifest_hash", manifest_path, errors)
    verify_hash(baseline, "baseline_hash", baseline_path, errors)
    verify_exact_fields(manifest, MANIFEST_FIELDS, manifest_path, errors)
    verify_exact_fields(baseline, BASELINE_FIELDS, baseline_path, errors)
    verify_top_level_values(manifest, baseline, manifest_path, baseline_path, errors)
    verify_install_pair(manifest, baseline, install_path, state_path, errors)
    verify_baseline_derived_fields(baseline, errors)
    verify_hook_entry_plan(manifest, baseline, errors)
    verify_fixture_manifest_records(baseline, errors)

    active_link = clean_path(baseline["active_runtime_link"])
    active_target = clean_path(baseline["active_runtime_target"])
    config_root = clean_path(baseline["config_root"])
    verify_active_runtime(active_link, active_target, errors)

    file_records = baseline_file_records(baseline, errors)
    file_records << current_install_manifest_record(manifest_path, errors)
    protected_inodes = verify_file_records(file_records, errors)
    verify_inode_index(baseline["protected_file_inode_index"], protected_inodes, errors)

    builtin_roots = [
      install_path,
      state_path,
      config_root,
      active_link,
      active_target
    ].compact.map(&:to_s)
    builtin_roots.concat(Array(baseline["provider_config_paths"]).map(&:to_s))
    builtin_roots << project_path.join(".strict-mode").to_s if project_path

    config_results = parse_config_files(config_root, builtin_roots, protected_inodes, errors, config_errors)
    configured_roots = protected_path_roots(config_results.fetch("protected-paths.txt", nil))
    destructive_patterns = config_results.fetch("destructive-patterns.txt", { "records" => [] }).fetch("records")

    roots = canonical_paths(builtin_roots + configured_roots)
    result(errors.empty?, errors, config_errors).merge(
      "install_root" => install_path.to_s,
      "state_root" => state_path.to_s,
      "config_root" => config_root.to_s,
      "project_dir" => project_path ? project_path.to_s : "",
      "home" => home_path.to_s,
      "manifest" => manifest,
      "baseline" => baseline,
      "protected_roots" => roots,
      "protected_inodes" => protected_inodes,
      "destructive_patterns" => destructive_patterns,
      "config_results" => config_results
    )
  end

  def load!(**kwargs)
    loaded = load(**kwargs)
    raise loaded.fetch("errors").join("; ") unless loaded.fetch("trusted")

    loaded
  end

  def result(trusted, errors, config_errors)
    {
      "trusted" => trusted,
      "errors" => errors,
      "config_errors" => config_errors,
      "manifest" => {},
      "baseline" => {},
      "protected_roots" => [],
      "protected_inodes" => [],
      "destructive_patterns" => [],
      "config_results" => {}
    }
  end

  def normalize_absolute(path, field, errors)
    normalized = Pathname.new(File.expand_path(path.to_s)).cleanpath
    errors << "#{field} must be absolute" unless normalized.absolute?
    normalized
  rescue ArgumentError
    errors << "#{field} is not normalizable"
    Pathname.new("/")
  end

  def clean_path(path)
    return nil if path.nil? || path.to_s.empty?

    Pathname.new(path.to_s).cleanpath
  rescue ArgumentError
    nil
  end

  def load_json(path, errors)
    errors << "#{path}: missing JSON file" unless path.file?
    errors << "#{path}: JSON file must not be a symlink" if path.symlink?
    return nil if errors.any? { |message| message.start_with?("#{path}:") }

    record = JSON.parse(path.read, object_class: DuplicateKeyHash)
    unless record.is_a?(Hash)
      errors << "#{path}: JSON root must be an object"
      return nil
    end
    JSON.parse(JSON.generate(record))
  rescue JSON::ParserError, RuntimeError => e
    errors << "#{path}: malformed JSON: #{e.message}"
    nil
  end

  def verify_hash(record, field, path, errors)
    expected = json_hash(record, field)
    errors << "#{path}: #{field} mismatch" unless record[field] == expected
  rescue RuntimeError => e
    errors << "#{path}: #{field} verification failed: #{e.message}"
  end

  def verify_exact_fields(record, expected_fields, path, errors)
    actual = record.keys.sort
    expected = expected_fields.sort
    return if actual == expected

    missing = expected - actual
    extra = actual - expected
    details = []
    details << "missing #{missing.join(", ")}" unless missing.empty?
    details << "extra #{extra.join(", ")}" unless extra.empty?
    errors << "#{path}: top-level fields mismatch (#{details.join("; ")})"
  end

  def verify_top_level_values(manifest, baseline, manifest_path, baseline_path, errors)
    verify_manifest_top_level_values(manifest, manifest_path, errors)
    verify_baseline_top_level_values(baseline, baseline_path, errors)
  end

  def verify_manifest_top_level_values(manifest, path, errors)
    errors << "#{path}: schema_version must be 1" unless manifest["schema_version"] == 1
    %w[
      transaction_id
      install_root
      active_runtime_link
      active_runtime_target
      state_root
      config_root
      package_version
      created_at
      updated_at
      manifest_hash
    ].each do |field|
      errors << "#{path}: #{field} must be a string" unless manifest[field].is_a?(String)
    end
    %w[transaction_id install_root active_runtime_link active_runtime_target state_root config_root package_version created_at updated_at].each do |field|
      errors << "#{path}: #{field} must be non-empty" if manifest[field].is_a?(String) && manifest[field].empty?
    end
    errors << "#{path}: manifest_hash must be lowercase SHA-256" unless manifest["manifest_hash"].is_a?(String) && manifest["manifest_hash"].match?(StrictModeHookEntryPlan::SHA256_PATTERN)
  end

  def verify_baseline_top_level_values(baseline, path, errors)
    errors << "#{path}: schema_version must be 1" unless baseline["schema_version"] == 1
    errors << "#{path}: kind must be protected-install-baseline" unless baseline["kind"] == "protected-install-baseline"
    %w[
      transaction_id
      install_root
      active_runtime_link
      active_runtime_target
      state_root
      config_root
      package_version
      install_manifest_hash
      created_at
      updated_at
      baseline_hash
    ].each do |field|
      errors << "#{path}: #{field} must be a string" unless baseline[field].is_a?(String)
    end
    %w[transaction_id install_root active_runtime_link active_runtime_target state_root config_root package_version created_at updated_at].each do |field|
      errors << "#{path}: #{field} must be non-empty" if baseline[field].is_a?(String) && baseline[field].empty?
    end
    %w[install_manifest_hash baseline_hash].each do |field|
      errors << "#{path}: #{field} must be lowercase SHA-256" unless baseline[field].is_a?(String) && baseline[field].match?(StrictModeHookEntryPlan::SHA256_PATTERN)
    end
  end

  def json_hash(record, field)
    clone = JSON.parse(JSON.generate(record))
    clone[field] = ""
    StrictModeMetadata.hash_record(clone, field)
  end

  def verify_install_pair(manifest, baseline, install_root, state_root, errors)
    errors << "baseline kind must be protected-install-baseline" unless baseline["kind"] == "protected-install-baseline"
    errors << "manifest install_root mismatch" unless manifest["install_root"] == install_root.to_s
    errors << "baseline install_root mismatch" unless baseline["install_root"] == install_root.to_s
    errors << "manifest state_root mismatch" unless manifest["state_root"] == state_root.to_s
    errors << "baseline state_root mismatch" unless baseline["state_root"] == state_root.to_s
    %w[
      active_runtime_link
      active_runtime_target
      config_root
      created_at
      fixture_manifest_records
      package_version
      protected_config_records
      provider_config_records
      runtime_config_records
      runtime_file_records
      transaction_id
      updated_at
    ].each do |field|
      errors << "manifest/baseline #{field} mismatch" unless manifest[field] == baseline[field]
    end
    errors << "baseline install_manifest_hash mismatch" unless baseline["install_manifest_hash"] == manifest["manifest_hash"]
  end

  def verify_baseline_derived_fields(baseline, errors)
    provider_records = baseline["provider_config_records"]
    provider_paths = baseline["provider_config_paths"]
    if provider_records.is_a?(Array) && provider_paths.is_a?(Array)
      expected_paths = provider_records.each_with_object([]) do |record, paths|
        paths << record["path"] if record.is_a?(Hash)
      end.sort
      errors << "baseline provider_config_paths mismatch provider_config_records" unless provider_paths == expected_paths
    else
      errors << "baseline provider_config_paths must be an array"
    end

    entries = baseline["managed_hook_entries"]
    generated_commands = baseline["generated_hook_commands"]
    if entries.is_a?(Array) && generated_commands.is_a?(Array)
      expected_commands = entries.each_with_object([]) do |entry, commands|
        next unless entry.is_a?(Hash)

        commands << {
          "provider" => entry["provider"],
          "hook_event" => entry["hook_event"],
          "logical_event" => entry["logical_event"],
          "command" => entry["command"]
        }
      end
      errors << "baseline generated_hook_commands mismatch managed_hook_entries" unless generated_commands == expected_commands
    else
      errors << "baseline generated_hook_commands must be an array"
    end

    generated_env = baseline["generated_hook_env"]
    if generated_env.is_a?(Hash)
      errors << "baseline generated_hook_env mismatch protected generated hook env" unless generated_env == EXPECTED_GENERATED_HOOK_ENV
    else
      errors << "baseline generated_hook_env must be an object"
    end
  end

  def verify_hook_entry_plan(manifest, baseline, errors)
    manifest_entries = required_array(manifest, "managed_hook_entries", "manifest", errors)
    baseline_entries = required_array(baseline, "managed_hook_entries", "baseline", errors)
    manifest_outputs = required_array(manifest, "selected_output_contracts", "manifest", errors)
    baseline_outputs = required_array(baseline, "selected_output_contracts", "baseline", errors)
    return unless manifest_entries && baseline_entries && manifest_outputs && baseline_outputs

    errors << "manifest/baseline managed_hook_entries mismatch" unless manifest_entries == baseline_entries
    errors << "manifest/baseline selected_output_contracts mismatch" unless manifest_outputs == baseline_outputs
    plan_errors = StrictModeHookEntryPlan.validate(
      manifest_entries,
      selected_output_contracts: manifest_outputs,
      enforce: enforcing_hook_plan?(manifest_entries, manifest_outputs),
      install_root: manifest["install_root"]
    )
    errors.concat(plan_errors.map { |message| "managed hook entry plan invalid: #{message}" })
  end

  def verify_fixture_manifest_records(baseline, errors)
    records = baseline["fixture_manifest_records"]
    unless records.is_a?(Array)
      errors << "baseline fixture_manifest_records must be an array"
      return
    end

    tuples = []
    records.each_with_index do |record, index|
      unless record.is_a?(Hash)
        errors << "fixture_manifest_records #{index}: must be an object"
        next
      end
      unless record.keys.sort == FIXTURE_MANIFEST_RECORD_FIELDS
        errors << "fixture_manifest_records #{index}: record fields mismatch"
        next
      end
      FIXTURE_MANIFEST_RECORD_FIELDS.each do |field|
        errors << "fixture_manifest_records #{index}: #{field} must be a string" unless record.fetch(field).is_a?(String)
      end
      errors << "fixture_manifest_records #{index}: unsupported provider #{record.fetch("provider").inspect}" unless %w[claude codex].include?(record.fetch("provider"))
      %w[provider_version platform event contract_kind contract_id].each do |field|
        errors << "fixture_manifest_records #{index}: #{field} must be non-empty" if record.fetch(field).is_a?(String) && record.fetch(field).empty?
      end
      %w[fixture_record_hash fixture_manifest_hash].each do |field|
        errors << "fixture_manifest_records #{index}: #{field} must be lowercase SHA-256" unless record.fetch(field).is_a?(String) && record.fetch(field).match?(StrictModeHookEntryPlan::SHA256_PATTERN)
      end
      tuples << fixture_manifest_record_sort_key(record)
    end
    errors << "fixture_manifest_records must be sorted" unless tuples == tuples.sort
    duplicate_tuples = tuples.each_with_object(Hash.new(0)) { |tuple, counts| counts[tuple] += 1 }.select { |_tuple, count| count > 1 }.keys
    errors << "fixture_manifest_records duplicate tuples" unless duplicate_tuples.empty?

    providers = Array(baseline["managed_hook_entries"]).select { |entry| entry.is_a?(Hash) }.map { |entry| entry["provider"] }.compact.uniq.sort & %w[claude codex]
    expected = StrictModeFixtureReadiness.fixture_manifest_records(StrictModeMetadata.project_root, providers)
    errors << "baseline fixture_manifest_records mismatch selected provider fixtures" unless records == expected
  rescue RuntimeError => e
    errors << "fixture_manifest_records verification failed: #{e.message}"
  end

  def fixture_manifest_record_sort_key(record)
    [
      record.fetch("provider", ""),
      record.fetch("platform", ""),
      record.fetch("event", ""),
      record.fetch("contract_kind", ""),
      record.fetch("contract_id", "")
    ]
  end

  def required_array(record, field, label, errors)
    value = record[field]
    unless value.is_a?(Array)
      errors << "#{label} #{field} must be an array"
      return nil
    end

    value
  end

  def enforcing_hook_plan?(entries, selected_output_contracts)
    !selected_output_contracts.empty? ||
      entries.any? do |entry|
        entry.is_a?(Hash) && (entry["enforcing"] == true || entry["output_contract_id"] != "")
      end
  end

  def verify_active_runtime(active_link, active_target, errors)
    if active_link.nil? || active_target.nil?
      errors << "active runtime paths must be present"
      return
    end
    errors << "#{active_link}: active runtime link must be a symlink" unless active_link.symlink?
    if active_link.symlink? && active_link.readlink.to_s != active_target.to_s
      errors << "#{active_link}: active runtime target mismatch"
    end
    errors << "#{active_target}: active runtime target must be a directory" unless active_target.directory?
  rescue SystemCallError => e
    errors << "active runtime verification failed: #{e.message}"
  end

  def baseline_file_records(baseline, errors)
    fields = %w[
      runtime_file_records
      runtime_config_records
      provider_config_records
      protected_config_records
    ]
    fields.flat_map do |field|
      value = baseline[field]
      unless value.is_a?(Array)
        errors << "#{field} must be an array"
        next []
      end
      verify_file_record_array_order(field, value, errors)
      value
    end
  end

  def verify_file_record_array_order(field, records, errors)
    keys = []
    records.each do |record|
      next unless record.is_a?(Hash) && record["path"].is_a?(String) && record["kind"].is_a?(String)

      keys << [record.fetch("path"), record.fetch("kind")]
    end
    errors << "#{field} must be sorted by path/kind" unless keys == keys.sort

    counts = Hash.new(0)
    keys.each { |key| counts[key] += 1 }
    counts.select { |_key, count| count > 1 }.keys.each do |path, kind|
      errors << "#{field} duplicate path/kind #{path} #{kind}"
    end
  end

  def verify_file_records(records, errors)
    records.each_with_object([]) do |record, inodes|
      unless record.is_a?(Hash)
        errors << "file record must be an object"
        next
      end
      unless record.keys.sort == FILE_RECORD_FIELDS
        errors << "file record fields mismatch"
        next
      end
      errors << "file record kind invalid" unless FILE_RECORD_KINDS.include?(record.fetch("kind"))
      errors << "file record provider must be a string" unless record.fetch("provider").is_a?(String)
      if record.fetch("provider").is_a?(String)
        if %w[provider-config fixture-manifest].include?(record.fetch("kind"))
          errors << "file record provider invalid for #{record.fetch("kind")}" unless %w[claude codex].include?(record.fetch("provider"))
        elsif record.fetch("provider") != ""
          errors << "file record provider must be empty for #{record.fetch("kind")}"
        end
      end
      path = clean_path(record["path"])
      if path.nil? || !path.absolute?
        errors << "file record path must be absolute"
        next
      end
      unless record.fetch("path").is_a?(String) && record.fetch("path") == path.to_s
        errors << "#{path}: file record path must be canonical"
        next
      end
      if record.fetch("exists", 0) != 1
        errors << "#{path}: protected file record is missing"
        next
      end
      if path.symlink?
        errors << "#{path}: protected file record must not be a symlink"
        next
      end
      unless path.file?
        errors << "#{path}: protected file record must be a file"
        next
      end

      stat = path.stat
      expected_hash = record.fetch("content_sha256", "")
      current_hash = Digest::SHA256.file(path).hexdigest
      errors << "#{path}: content_sha256 mismatch" unless expected_hash == current_hash
      if record.key?("dev") && record.key?("inode") && record["dev"].to_i.positive? && record["inode"].to_i.positive?
        errors << "#{path}: dev/inode mismatch" unless record["dev"] == stat.dev && record["inode"] == stat.ino
      else
        errors << "#{path}: protected file record missing dev/inode"
      end
      if record.key?("realpath") && !record["realpath"].to_s.empty?
        errors << "#{path}: realpath mismatch" unless record["realpath"] == path.realpath.to_s
      else
        errors << "#{path}: protected file record missing realpath"
      end
      if record.key?("owner_uid") && record["owner_uid"].is_a?(Integer)
        errors << "#{path}: owner_uid mismatch" unless record["owner_uid"] == stat.uid
      else
        errors << "#{path}: protected file record missing owner_uid"
      end
      if record.key?("mode") && record["mode"].is_a?(Integer)
        errors << "#{path}: mode mismatch" unless record["mode"] == (stat.mode & 0o7777)
      else
        errors << "#{path}: protected file record missing mode"
      end
      if record.key?("size_bytes") && record["size_bytes"].is_a?(Integer)
        errors << "#{path}: size_bytes mismatch" unless record["size_bytes"] == stat.size
      else
        errors << "#{path}: protected file record missing size_bytes"
      end

      inodes << {
        "dev" => stat.dev,
        "inode" => stat.ino,
        "path" => path.to_s,
        "kind" => record.fetch("kind", ""),
        "provider" => record.fetch("provider", ""),
        "content_sha256" => current_hash
      }
    rescue KeyError => e
      errors << "#{path || '<unknown>'}: file record missing #{e.key}"
    rescue SystemCallError => e
      errors << "#{path}: file record verification failed: #{e.message}"
    end
  end

  def current_install_manifest_record(path, errors)
    unless path.file? && !path.symlink?
      errors << "#{path}: install manifest must be a non-symlink file"
      return {}
    end

    stat = path.stat
    {
      "path" => path.to_s,
      "realpath" => path.realpath.to_s,
      "kind" => "install-manifest",
      "provider" => "",
      "exists" => 1,
      "mode" => stat.mode & 0o7777,
      "owner_uid" => stat.uid,
      "dev" => stat.dev,
      "inode" => stat.ino,
      "size_bytes" => stat.size,
      "content_sha256" => Digest::SHA256.file(path).hexdigest
    }
  rescue SystemCallError => e
    errors << "#{path}: install manifest fingerprint failed: #{e.message}"
    {}
  end

  def verify_inode_index(index, protected_inodes, errors)
    unless index.is_a?(Hash)
      errors << "protected_file_inode_index must be an object"
      return
    end
    errors << "protected_file_inode_index must not be empty" if index.empty?
    indexed_keys = index.keys.sort
    expected_keys = protected_inodes.map { |inode| "#{inode.fetch("dev")}:#{inode.fetch("inode")}" }.uniq.sort
    missing = expected_keys - indexed_keys
    extra = indexed_keys - expected_keys
    errors << "protected_file_inode_index missing keys #{missing.join(", ")}" unless missing.empty?
    errors << "protected_file_inode_index has stale keys #{extra.join(", ")}" unless extra.empty?
    return unless missing.empty? && extra.empty?

    expected = expected_inode_index(protected_inodes)
    expected.each do |key, expected_entries|
      actual_entries = canonical_inode_index_entries(index.fetch(key), key, errors)
      next unless actual_entries

      if actual_entries != expected_entries
        errors << "protected_file_inode_index entry mismatch for #{key}"
      end
    end
  end

  def expected_inode_index(protected_inodes)
    grouped = {}
    protected_inodes.each do |inode|
      key = "#{inode.fetch("dev")}:#{inode.fetch("inode")}"
      grouped[key] ||= []
      grouped[key] << {
        "dev" => inode.fetch("dev"),
        "inode" => inode.fetch("inode"),
        "path" => inode.fetch("path"),
        "kind" => inode.fetch("kind"),
        "provider" => inode.fetch("provider"),
        "content_sha256" => inode.fetch("content_sha256")
      }
    end
    grouped.keys.sort.each_with_object({}) do |key, expected|
      expected[key] = grouped.fetch(key).uniq.sort_by { |entry| [entry.fetch("path"), entry.fetch("kind"), entry.fetch("provider"), entry.fetch("content_sha256")] }
    end
  end

  def canonical_inode_index_entries(value, key, errors)
    unless value.is_a?(Array)
      errors << "protected_file_inode_index #{key} must be an array"
      return nil
    end
    entries = []
    value.each do |entry|
      unless entry.is_a?(Hash)
        errors << "protected_file_inode_index #{key} entries must be objects"
        return nil
      end
      unless entry.keys.sort == INODE_INDEX_ENTRY_FIELDS
        errors << "protected_file_inode_index #{key} entry fields mismatch"
        return nil
      end
      entries << JSON.parse(JSON.generate(entry))
    end
    if entries.uniq.size != entries.size
      errors << "protected_file_inode_index #{key} contains duplicate entries"
      return nil
    end
    entries.sort_by { |entry| [entry.fetch("path"), entry.fetch("kind"), entry.fetch("provider"), entry.fetch("content_sha256")] }
  end

  def parse_config_files(config_root, protected_roots, protected_inodes, errors, config_errors)
    return {} unless config_root

    CONFIG_KINDS.each_with_object({}) do |(file, kind), results|
      path = config_root.join(file)
      result = StrictModeProtectedConfig.parse_file(
        path,
        kind: kind,
        protected_roots: protected_roots,
        protected_inodes: protected_inodes
      )
      results[file] = result
      result.fetch("errors").each { |message| errors << "#{path}: #{message}" }
      result.fetch("config_errors").each { |message| config_errors << "#{path}: #{message}" }
    end
  end

  def protected_path_roots(result)
    return [] unless result && result.fetch("trusted", false)

    result.fetch("records").map { |record| record.fetch("path") }
  end

  def canonical_paths(paths)
    paths.compact.map do |path|
      Pathname.new(path.to_s).cleanpath.to_s
    rescue ArgumentError
      nil
    end.compact.uniq.sort
  end
end
