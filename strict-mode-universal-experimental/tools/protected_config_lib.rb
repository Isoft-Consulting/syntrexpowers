#!/usr/bin/env ruby
# frozen_string_literal: true

require "ipaddr"
require "json"
require "pathname"

module StrictModeProtectedConfig
  extend self

  DEFAULT_LINE_MAX_BYTES = 4096
  KINDS = %w[
    runtime-env
    protected-paths
    destructive-patterns
    stub-allowlist
    filesystem-read-allowlist
    network-allowlist
    user-prompt-injection
    judge-prompt-template
  ].freeze
  RAW_TEXT_KINDS = %w[
    user-prompt-injection
    judge-prompt-template
  ].freeze
  SHA256_PATTERN = /\A[a-f0-9]{64}\z/
  BOOL_KEYS = %w[
    STRICT_NO_ARTIFACT_GATE
    STRICT_CAPTURE_RAW_PAYLOADS
    STRICT_CAPTURE_FULL_TEXT
    STRICT_NO_HAIKU_JUDGE
    STRICT_NO_CODEX_JUDGE
    STRICT_NO_CLAUDE_WORKER
    STRICT_NO_CODEX_WORKER
    STRICT_LEGACY_CLAUDE_OPTOUTS
  ].freeze
  INTEGER_BOUNDS = {
    "STRICT_LOG_VALUE_MAX_BYTES" => [256, 65_536],
    "STRICT_LOG_MAX_BYTES" => [1_048_576, 104_857_600],
    "STRICT_LOG_MAX_AGE_DAYS" => [1, 365],
    "STRICT_CONFIRM_MAX_AGE_SEC" => [30, 86_400],
    "STRICT_CONFIRM_MIN_AGE_SEC" => [0, 60],
    "STRICT_FDR_SOURCE_MAX_BYTES" => [65_536, 10_485_760],
    "STRICT_DIRTY_IGNORED_MAX_FILES" => [0, 100_000],
    "STRICT_APPROVAL_EVIDENCE_CAP" => [1, 100_000],
    "STRICT_CONFIG_LINE_MAX_BYTES" => [256, 65_536],
    "STRICT_JUDGE_TIMEOUT_SEC" => [5, 300],
    "STRICT_WORKER_TIMEOUT_SEC" => [5, 300],
    "STRICT_WORKER_CONTEXT_MAX_BYTES" => [4_096, 1_048_576],
    "STRICT_WORKER_RESULT_MAX_BYTES" => [1_024, 262_144]
  }.freeze
  MODEL_VALUES = {
    "STRICT_CLAUDE_JUDGE_MODEL" => ["claude-haiku-4-5-20251001"],
    "STRICT_CODEX_JUDGE_MODEL" => ["gpt-5.3-codex-spark"],
    "STRICT_CLAUDE_WORKER_MODEL" => ["claude-haiku-4-5-20251001"],
    "STRICT_CODEX_WORKER_MODEL" => ["gpt-5.3-codex-spark"]
  }.freeze
  RUNTIME_KEYS = (BOOL_KEYS + INTEGER_BOUNDS.keys + MODEL_VALUES.keys).sort.freeze

  def parse_file(path, kind:, line_max_bytes: DEFAULT_LINE_MAX_BYTES, protected_roots: [], protected_inodes: [])
    raise ArgumentError, "kind must be one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
    raise ArgumentError, "line_max_bytes must be integer 1..65536" unless line_max_bytes.is_a?(Integer) && line_max_bytes.between?(1, 65_536)

    bytes = Pathname.new(path).binread
    parse_bytes(
      bytes,
      kind: kind,
      source: Pathname.new(path).to_s,
      line_max_bytes: line_max_bytes,
      protected_roots: protected_roots,
      protected_inodes: protected_inodes
    )
  rescue SystemCallError => e
    result(kind, Pathname.new(path).to_s, [], ["could not read config: #{e.message}"], [])
  end

  def parse_bytes(bytes, kind:, source: "<bytes>", line_max_bytes: DEFAULT_LINE_MAX_BYTES, protected_roots: [], protected_inodes: [])
    raise ArgumentError, "kind must be one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
    errors = []
    config_errors = []
    records = []
    text = decode_utf8(bytes, errors)
    return result(kind, source, records, errors, config_errors) unless errors.empty?

    if RAW_TEXT_KINDS.include?(kind)
      # Raw-text configs preserve markdown headers, leading whitespace, and
      # blank lines. The directive parser would otherwise treat `#` as a
      # comment and reject useful prompt-template formatting.
      total_bytes = bytes.bytesize
      max_total = line_max_bytes * 256
      if total_bytes > max_total
        errors << "#{kind} exceeds #{max_total} bytes (#{total_bytes})"
        return result(kind, source, records, errors, config_errors)
      end
      records << { "directive" => "text", "content" => text } unless text.empty?
      return result(kind, source, records, errors, config_errors)
    end

    logical_lines(text).each do |line|
      parsed = parse_physical_line(line, kind, line_max_bytes)
      errors.concat(parsed.fetch("fatal_errors"))
      if parsed.fetch("line_errors").any?
        if allowlist_kind?(kind)
          config_errors.concat(parsed.fetch("line_errors"))
        else
          errors.concat(parsed.fetch("line_errors"))
        end
      end
      next if parsed.fetch("skip") || parsed.fetch("fatal_errors").any? || parsed.fetch("line_errors").any?

      line_records, line_errors = parse_config_line(
        parsed.fetch("text"),
        kind,
        protected_roots: protected_roots,
        protected_inodes: protected_inodes
      )
      if allowlist_kind?(kind)
        config_errors.concat(line_errors)
        records.concat(line_records)
      else
        errors.concat(line_errors)
        records.concat(line_records)
      end
    end
    if kind == "runtime-env" && errors.empty?
      errors.concat(validate_runtime_cross_rules(records))
    end
    records = canonicalize_records(kind, records)
    result(kind, source, records, errors, config_errors)
  end

  def result(kind, source, records, errors, config_errors)
    {
      "schema_id" => schema_id(kind),
      "kind" => kind,
      "source" => source,
      "trusted" => errors.empty?,
      "records" => records,
      "errors" => errors,
      "config_errors" => config_errors
    }
  end

  def schema_id(kind)
    "config.#{kind}.v1"
  end

  def decode_utf8(bytes, errors)
    if bytes.include?("\0")
      errors << "config contains NUL byte"
      return ""
    end
    text = bytes.dup.force_encoding("UTF-8")
    unless text.valid_encoding?
      errors << "config must be valid UTF-8"
      return ""
    end
    text
  end

  def logical_lines(text)
    lines = text.split("\n", -1)
    lines.pop if text.end_with?("\n")
    lines.each_with_index.map { |line, index| { "number" => index + 1, "text" => line } }
  end

  def parse_physical_line(line, kind, line_max_bytes)
    number = line.fetch("number")
    text = line.fetch("text")
    fatal_errors = []
    fatal_errors << "line #{number}: exceeds STRICT_CONFIG_LINE_MAX_BYTES" if text.bytesize > line_max_bytes
    fatal_errors << "line #{number}: CR characters are not supported" if text.include?("\r")
    return { "skip" => true, "text" => "", "fatal_errors" => fatal_errors, "line_errors" => [] } unless fatal_errors.empty?

    return { "skip" => true, "text" => "", "fatal_errors" => [], "line_errors" => [] } if text.strip.empty?
    return { "skip" => true, "text" => "", "fatal_errors" => [], "line_errors" => [] } if text.start_with?("#")

    line_errors = []
    line_errors << "line #{number}: leading or trailing whitespace is not allowed" unless text == text.strip
    line_errors << "line #{number}: inline comments are not supported" if text.include?("#")
    line_errors << "line #{number}: invalid #{kind} line" unless line_errors.empty?
    { "skip" => false, "text" => text, "fatal_errors" => [], "line_errors" => line_errors }
  end

  def parse_config_line(line, kind, protected_roots: [], protected_inodes: [])
    case kind
    when "runtime-env"
      parse_runtime_env_line(line)
    when "protected-paths"
      parse_path_directive(line, "protect-file", "protect-tree", require_existing: false)
    when "destructive-patterns"
      parse_destructive_line(line)
    when "stub-allowlist"
      parse_stub_line(line)
    when "filesystem-read-allowlist"
      parse_path_directive(
        line,
        "read",
        "read-tree",
        require_existing: true,
        protected_roots: protected_roots,
        protected_inodes: protected_inodes
      )
    when "network-allowlist"
      parse_network_line(line)
    when *RAW_TEXT_KINDS
      # Raw-text kinds are handled before per-line dispatch. This fallback keeps
      # direct parser calls deterministic without giving the line parser any
      # executable semantics.
      [[{ "directive" => "text", "content" => line }], []]
    else
      [[], ["unknown config kind #{kind}"]]
    end
  end

  def parse_runtime_env_line(line)
    return [[], ["runtime env line must be KEY=VALUE"]] unless line.count("=") == 1

    key, value = line.split("=", 2)
    errors = []
    errors << "runtime env key must be whitelisted" unless RUNTIME_KEYS.include?(key)
    errors << "runtime env value contains unsupported shell or quoting syntax" if runtime_value_unsafe?(value)
    validate_runtime_value(errors, key, value) if RUNTIME_KEYS.include?(key)
    return [[], errors] unless errors.empty?

    [[{ "key" => key, "value" => value }], []]
  end

  def runtime_value_unsafe?(value)
    value.empty? || value.match?(/[\s`\\*?\[\]{}()"'<>|;&]/) || value.include?("$")
  end

  def validate_runtime_value(errors, key, value)
    if BOOL_KEYS.include?(key)
      errors << "#{key} must be 0 or 1" unless %w[0 1].include?(value)
    elsif INTEGER_BOUNDS.key?(key)
      min, max = INTEGER_BOUNDS.fetch(key)
      unless value.match?(/\A(?:0|[1-9][0-9]*)\z/) && value.to_i.between?(min, max)
        errors << "#{key} must be integer #{min}..#{max}"
      end
    elsif MODEL_VALUES.key?(key)
      errors << "#{key} must be one of #{MODEL_VALUES.fetch(key).join(", ")}" unless MODEL_VALUES.fetch(key).include?(value)
    end
  end

  def validate_runtime_cross_rules(records)
    errors = []
    by_key = records.group_by { |record| record.fetch("key") }
    by_key.each do |key, values|
      errors << "#{key} appears more than once" if values.length > 1
    end
    settings = records.each_with_object({}) { |record, map| map[record.fetch("key")] = record.fetch("value") }
    min_age = settings["STRICT_CONFIRM_MIN_AGE_SEC"]
    max_age = settings["STRICT_CONFIRM_MAX_AGE_SEC"]
    if min_age && max_age && min_age.to_i > max_age.to_i
      errors << "STRICT_CONFIRM_MIN_AGE_SEC must not exceed STRICT_CONFIRM_MAX_AGE_SEC"
    end
    if settings["STRICT_NO_HAIKU_JUDGE"] == "1" && settings["STRICT_NO_CODEX_JUDGE"] == "1"
      errors << "STRICT_NO_HAIKU_JUDGE and STRICT_NO_CODEX_JUDGE must not both be 1"
    end
    %w[STRICT_NO_CLAUDE_WORKER STRICT_NO_CODEX_WORKER].each do |key|
      if settings[key] == "0"
        errors << "#{key}=0 requires protected worker-invocation fixture proof"
      end
    end
    errors
  end

  def parse_path_directive(line, file_directive, tree_directive, require_existing:, protected_roots: [], protected_inodes: [])
    parts = split_exact_fields(line)
    return [[], ["#{file_directive}/#{tree_directive} line must have exactly two fields"]] unless parts.length == 2

    directive, target = parts
    return [[], ["unknown path directive #{directive.inspect}"]] unless [file_directive, tree_directive].include?(directive)

    tree = directive == tree_directive
    if tree
      return [[], ["#{tree_directive} target must end with /**"]] unless target.end_with?("/**")

      target = target.delete_suffix("/**")
    elsif target.end_with?("/**")
      return [[], ["#{file_directive} target must not use /** suffix"]]
    end

    errors = validate_absolute_path(
      target,
      tree: tree,
      require_existing: require_existing,
      protected_roots: protected_roots,
      protected_inodes: protected_inodes
    )
    return [[], errors] unless errors.empty?

    record = {
      "directive" => directive,
      "path" => target,
      "scope" => tree ? "tree" : "file"
    }
    [record_existing_metadata(record, target, require_existing), []]
  end

  def record_existing_metadata(record, target, require_existing)
    path = Pathname.new(target)
    return [record] unless require_existing && path.exist?

    stat = path.stat
    [record.merge("dev" => stat.dev, "inode" => stat.ino)]
  end

  def validate_absolute_path(target, tree:, require_existing:, protected_roots:, protected_inodes:)
    errors = []
    path = Pathname.new(target)
    errors << "path must be absolute" unless path.absolute?
    errors << "path must be normalized" unless path.cleanpath.to_s == target
    errors << "path must not be root" if target == "/"
    errors << "path must not have trailing slash ambiguity" if target.length > 1 && target.end_with?("/")
    errors << "path must not contain shell, glob, or expansion syntax" if target.match?(/[\0\r\n`$;&|<>?*\[\]{}\\"']/)
    errors << "path must not contain symlink components" if path.absolute? && symlink_component?(path)
    if require_existing && protected_roots.any? { |root| path_inside?(target, root.to_s) }
      errors << "read allowlist target must be outside protected roots"
    end
    if require_existing && errors.empty?
      if tree
        errors << "read-tree target must be an existing non-symlink directory" unless path.directory? && !path.symlink?
      else
        errors << "read target must be an existing non-symlink file" unless path.file? && !path.symlink?
      end
      if errors.empty? && protected_inode?(path, protected_inodes)
        errors << "read allowlist target matches protected dev+inode"
      end
    end
    errors
  end

  def path_inside?(target, root)
    clean_target = Pathname.new(target).cleanpath.to_s
    clean_root = Pathname.new(root).cleanpath.to_s
    clean_target == clean_root || clean_target.start_with?("#{clean_root}/")
  end

  def protected_inode?(path, protected_inodes)
    return false unless path.exist?

    stat = path.stat
    protected_inodes.any? do |item|
      dev, inode = inode_tuple(item)
      dev == stat.dev && inode == stat.ino
    end
  end

  def inode_tuple(item)
    case item
    when Hash
      [item["dev"] || item[:dev], item["inode"] || item[:inode]]
    when Array
      item
    else
      [nil, nil]
    end
  end

  def symlink_component?(path)
    current = Pathname.new("/")
    path.each_filename do |part|
      current = current.join(part)
      return true if current.symlink?
      return false unless current.exist?
    end
    false
  end

  def parse_destructive_line(line)
    directive, body = split_directive_body(line)
    case directive
    when "shell-ere"
      parse_shell_ere(body)
    when "argv-token"
      parse_argv_token(body)
    else
      [[], ["unknown destructive directive #{directive.inspect}"]]
    end
  end

  def parse_shell_ere(pattern)
    return [[], ["shell-ere pattern must be non-empty"]] if pattern.empty?
    return [[], ["shell-ere pattern contains unsupported shell expansion syntax"]] if pattern.include?("`") || pattern.include?("$(") || pattern.include?("${")

    Regexp.new(pattern)
    [[{ "directive" => "shell-ere", "pattern" => pattern }], []]
  rescue RegexpError => e
    [[], ["shell-ere pattern does not compile: #{e.message}"]]
  end

  def parse_argv_token(token)
    errors = []
    errors << "argv-token must be a single literal token" if token.empty? || token.match?(/\s/)
    errors << "argv-token contains unsupported shell, glob, or expansion syntax" if token.match?(/[`$;&|<>*?\[\]{}\\"'()]/)
    return [[], errors] unless errors.empty?

    [[{ "directive" => "argv-token", "token" => token }], []]
  end

  def parse_stub_line(line)
    parts = split_exact_fields(line)
    return [[], ["stub allowlist line must have exactly two fields"]] unless parts.length == 2
    return [[], ["stub allowlist directive must be finding"]] unless parts[0] == "finding"
    return [[], ["finding digest must be lowercase SHA-256"]] unless parts[1].match?(SHA256_PATTERN)

    [[{ "directive" => "finding", "finding_digest" => parts[1] }], []]
  end

  def parse_network_line(line)
    parts = split_exact_fields(line)
    return [[], ["network allowlist line must have exactly four fields"]] unless parts.length == 4

    operation, scheme, host, port_text = parts
    errors = []
    errors << "network operation must be connect" unless operation == "connect"
    errors << "network scheme must be http or https" unless %w[http https].include?(scheme)
    errors << "network host must be canonical lowercase hostname or literal IP" unless valid_network_host?(host)
    errors << "network port must be integer 1..65535" unless port_text.match?(/\A[1-9][0-9]{0,4}\z/) && port_text.to_i.between?(1, 65_535)
    return [[], errors] unless errors.empty?

    [[{ "operation" => operation, "scheme" => scheme, "host" => host, "port" => port_text.to_i }], []]
  end

  def valid_network_host?(host)
    return false if host.empty? || host != host.downcase
    return false if host.match?(/[*\/@?#\[\]{}\\`$&|<>;"']/)
    return true if literal_ip?(host)
    return false if host.include?(":") || host.length > 253

    labels = host.split(".")
    return false if labels.empty? || labels.any?(&:empty?)

    labels.all? { |label| label.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/) }
  end

  def literal_ip?(host)
    IPAddr.new(host)
    true
  rescue ArgumentError
    false
  end

  def split_exact_fields(line)
    parts = line.split(" ", -1)
    return [] if parts.any?(&:empty?)

    parts
  end

  def split_directive_body(line)
    index = line.index(" ")
    return [line, ""] unless index

    directive = line[0...index]
    body = line[(index + 1)..]
    return [directive, ""] if body.nil? || body.empty? || body != body.strip

    [directive, body]
  end

  def allowlist_kind?(kind)
    %w[filesystem-read-allowlist network-allowlist].include?(kind)
  end

  def canonicalize_records(kind, records)
    records.uniq.sort_by { |record| JSON.generate(record.sort.to_h) }.tap do |sorted|
      return sorted unless kind == "runtime-env"

      sorted.sort_by! { |record| record.fetch("key") }
    end
  end
end
