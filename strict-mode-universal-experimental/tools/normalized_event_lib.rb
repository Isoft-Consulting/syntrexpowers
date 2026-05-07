#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "uri"
require_relative "fixture_manifest_lib"

module StrictModeNormalized
  extend self

  PROVIDERS = %w[claude codex unknown].freeze
  LOGICAL_EVENTS = %w[
    session-start
    user-prompt-submit
    pre-tool-use
    post-tool-use
    stop
    subagent-stop
    permission-request
  ].freeze
  TOOL_KINDS = %w[shell write edit multi-edit patch read other unknown].freeze
  WRITE_INTENTS = %w[none read write unknown].freeze
  CHANGE_ACTIONS = %w[create modify delete rename unknown].freeze
  CHANGE_SOURCES = %w[payload patch dirty-snapshot].freeze
  PERMISSION_OPERATIONS = %w[tool shell write network filesystem combined unknown].freeze
  ACCESS_MODES = %w[read write execute delete chmod network-connect network-listen unknown].freeze
  FILESYSTEM_ACCESS_MODES = %w[read write execute delete chmod unknown].freeze
  FILESYSTEM_RECURSIVE = %w[true false unknown].freeze
  FILESYSTEM_SCOPES = %w[file directory project home root unknown].freeze
  NETWORK_SCHEMES = %w[http https unknown].freeze
  NETWORK_OPERATIONS = %w[connect listen proxy tunnel unknown].freeze
  CAN_APPROVE = %w[true false unknown].freeze
  TOP_FIELDS = %w[
    schema_version
    provider
    logical_event
    raw_event
    session_id
    parent_session_id
    turn_id
    cwd
    project_dir
    transcript_path
    turn
    tool
    permission
    prompt
    assistant
    raw
  ].freeze
  TURN_FIELDS = %w[assistant_text assistant_text_bytes assistant_text_truncated edit_count has_fdr_context].freeze
  TOOL_FIELDS = %w[name kind write_intent command file_path file_paths file_changes content old_string new_string patch].freeze
  CHANGE_FIELDS = %w[path old_path new_path action source].freeze
  PERMISSION_FIELDS = %w[
    request_id
    operation
    access_mode
    requested_tool_kind
    requested_command
    requested_paths
    filesystem
    network
    can_approve
  ].freeze
  FILESYSTEM_FIELDS = %w[access_mode paths recursive scope].freeze
  NETWORK_FIELDS = %w[scheme host port operation url].freeze
  PROMPT_FIELDS = %w[text].freeze
  ASSISTANT_FIELDS = %w[last_message].freeze
  RAW_FIELDS = %w[payload_sha256 event_name logical_event_mismatch provider_indicators].freeze
  NATIVE_EVENT_MAP = {
    "SessionStart" => "session-start",
    "UserPromptSubmit" => "user-prompt-submit",
    "PreToolUse" => "pre-tool-use",
    "PostToolUse" => "post-tool-use",
    "Stop" => "stop",
    "SubagentStop" => "subagent-stop",
    "PermissionRequest" => "permission-request"
  }.freeze
  TOOL_KIND_MAP = {
    "bash" => "shell",
    "shell" => "shell",
    "exec_command" => "shell",
    "write" => "write",
    "edit" => "edit",
    "multiedit" => "multi-edit",
    "multi_edit" => "multi-edit",
    "multi-edit" => "multi-edit",
    "apply_patch" => "patch",
    "patch" => "patch",
    "read" => "read",
    "ls" => "read",
    "grep" => "read",
    "glob" => "read"
  }.freeze

  def load_payload(path)
    payload = Pathname.new(path).binread
    parsed = JSON.parse(payload, object_class: StrictModeFixtures::DuplicateKeyHash)
    raise "#{path}: payload JSON root must be an object" unless parsed.is_a?(Hash)

    [payload, JSON.parse(JSON.generate(parsed))]
  rescue JSON::ParserError, SystemCallError, RuntimeError => e
    raise "#{path}: malformed payload JSON: #{e.message}"
  end

  def normalize(payload, provider:, logical_event:, cwd:, project_dir:, payload_sha256: nil)
    provider = provider.to_s
    logical_event = logical_event.to_s
    raise "provider must be claude, codex, or unknown" unless PROVIDERS.include?(provider)
    raise "logical_event must be a supported logical event" unless LOGICAL_EVENTS.include?(logical_event)

    cwd = normalize_identity_path(cwd, "cwd")
    project_dir = normalize_identity_path(project_dir, "project_dir")
    raise "cwd must be equal to or inside project_dir" unless path_inside?(cwd, project_dir)

    raw_event = raw_event_name(payload, logical_event)
    mapped_event = native_logical_event(raw_event)
    mismatch = !mapped_event.empty? && mapped_event != logical_event
    raise "logical event mismatch: payload #{raw_event.inspect} maps to #{mapped_event.inspect}, argv is #{logical_event.inspect}" if mismatch

    tool = normalize_tool(payload, logical_event)
    tool = unknown_provider_tool(tool, logical_event) if provider == "unknown"
    permission = normalize_permission(payload, logical_event, tool)
    assistant_text = bounded_string(first_string(payload, "assistant_text", "turn_assistant_text"))
    prompt_text = logical_event == "user-prompt-submit" ? bounded_string(first_string(payload, "prompt", "user_prompt", "message")) : ""

    event = {
      "schema_version" => 1,
      "provider" => provider,
      "logical_event" => logical_event,
      "raw_event" => raw_event,
      "session_id" => bounded_string(first_string(payload, "session_id", "session", "conversation_id", "thread_id")),
      "parent_session_id" => bounded_string(first_string(payload, "parent_session_id", "parentSessionId")),
      "turn_id" => "",
      "cwd" => cwd,
      "project_dir" => project_dir,
      "transcript_path" => absolute_or_empty(first_string(payload, "transcript_path", "transcriptPath")),
      "turn" => {
        "assistant_text" => assistant_text,
        "assistant_text_bytes" => assistant_text.bytesize,
        "assistant_text_truncated" => 0,
        "edit_count" => tool.fetch("file_changes").length,
        "has_fdr_context" => false
      },
      "tool" => tool,
      "permission" => permission,
      "prompt" => {
        "text" => prompt_text
      },
      "assistant" => {
        "last_message" => bounded_string(first_string(payload, "last_message", "assistant_message"))
      },
      "raw" => {
        "payload_sha256" => payload_sha256 || Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(payload)),
        "event_name" => raw_event,
        "logical_event_mismatch" => false,
        "provider_indicators" => provider_indicators(payload)
      }
    }
    errors = validate(event)
    raise errors.join("\n") unless errors.empty?

    event
  end

  def validate(event)
    errors = []
    expect_exact_fields(errors, event, TOP_FIELDS, "event")
    return errors unless event.is_a?(Hash)

    expect(errors, event["schema_version"] == 1, "event.schema_version must be 1")
    expect_in(errors, event["provider"], PROVIDERS, "event.provider")
    expect_in(errors, event["logical_event"], LOGICAL_EVENTS, "event.logical_event")
    %w[raw_event session_id parent_session_id turn_id cwd project_dir transcript_path].each do |field|
      expect_string(errors, event[field], "event.#{field}")
    end
    validate_identity_paths(errors, event)
    validate_turn(errors, event["turn"])
    validate_tool(errors, event["tool"])
    validate_permission(errors, event["permission"])
    validate_prompt(errors, event["prompt"])
    validate_assistant(errors, event["assistant"])
    validate_raw(errors, event["raw"])
    errors
  end

  def validate_turn(errors, turn)
    expect_exact_fields(errors, turn, TURN_FIELDS, "event.turn")
    return unless turn.is_a?(Hash)

    expect_string(errors, turn["assistant_text"], "event.turn.assistant_text")
    expect(errors, turn["assistant_text_bytes"].is_a?(Integer) && turn["assistant_text_bytes"] >= 0, "event.turn.assistant_text_bytes must be a non-negative integer")
    expect(errors, turn["assistant_text_bytes"] == turn["assistant_text"].to_s.bytesize, "event.turn.assistant_text_bytes must match assistant_text bytes") if turn["assistant_text"].is_a?(String)
    expect_in(errors, turn["assistant_text_truncated"], [0, 1], "event.turn.assistant_text_truncated")
    expect(errors, turn["edit_count"].is_a?(Integer) && turn["edit_count"] >= 0, "event.turn.edit_count must be a non-negative integer")
    expect(errors, turn["has_fdr_context"] == true || turn["has_fdr_context"] == false, "event.turn.has_fdr_context must be boolean")
  end

  def validate_tool(errors, tool)
    expect_exact_fields(errors, tool, TOOL_FIELDS, "event.tool")
    return unless tool.is_a?(Hash)

    %w[name command file_path content old_string new_string patch].each do |field|
      expect_string(errors, tool[field], "event.tool.#{field}")
    end
    expect_in(errors, tool["kind"], TOOL_KINDS, "event.tool.kind")
    expect_in(errors, tool["write_intent"], WRITE_INTENTS, "event.tool.write_intent")
    expect_string_array(errors, tool["file_paths"], "event.tool.file_paths")
    expect(errors, tool["file_changes"].is_a?(Array), "event.tool.file_changes must be an array")
    return unless tool["file_changes"].is_a?(Array)

    tool["file_changes"].each_with_index do |change, index|
      validate_change(errors, change, "event.tool.file_changes[#{index}]")
    end
  end

  def validate_change(errors, change, label)
    expect_exact_fields(errors, change, CHANGE_FIELDS, label)
    return unless change.is_a?(Hash)

    %w[path old_path new_path].each { |field| expect_string(errors, change[field], "#{label}.#{field}") }
    expect_in(errors, change["action"], CHANGE_ACTIONS, "#{label}.action")
    expect_in(errors, change["source"], CHANGE_SOURCES, "#{label}.source")
  end

  def validate_permission(errors, permission)
    expect_exact_fields(errors, permission, PERMISSION_FIELDS, "event.permission")
    return unless permission.is_a?(Hash)

    %w[request_id requested_command].each { |field| expect_string(errors, permission[field], "event.permission.#{field}") }
    expect_in(errors, permission["operation"], PERMISSION_OPERATIONS, "event.permission.operation")
    expect_in(errors, permission["access_mode"], ACCESS_MODES, "event.permission.access_mode")
    expect_in(errors, permission["requested_tool_kind"], TOOL_KINDS, "event.permission.requested_tool_kind")
    expect_string_array(errors, permission["requested_paths"], "event.permission.requested_paths")
    validate_filesystem(errors, permission["filesystem"])
    validate_network(errors, permission["network"])
    expect_in(errors, permission["can_approve"], CAN_APPROVE, "event.permission.can_approve")
  end

  def validate_filesystem(errors, filesystem)
    expect_exact_fields(errors, filesystem, FILESYSTEM_FIELDS, "event.permission.filesystem")
    return unless filesystem.is_a?(Hash)

    expect_in(errors, filesystem["access_mode"], FILESYSTEM_ACCESS_MODES, "event.permission.filesystem.access_mode")
    expect_string_array(errors, filesystem["paths"], "event.permission.filesystem.paths")
    expect_in(errors, filesystem["recursive"], FILESYSTEM_RECURSIVE, "event.permission.filesystem.recursive")
    expect_in(errors, filesystem["scope"], FILESYSTEM_SCOPES, "event.permission.filesystem.scope")
  end

  def validate_network(errors, network)
    expect_exact_fields(errors, network, NETWORK_FIELDS, "event.permission.network")
    return unless network.is_a?(Hash)

    expect_in(errors, network["scheme"], NETWORK_SCHEMES, "event.permission.network.scheme")
    expect_string(errors, network["host"], "event.permission.network.host")
    expect(errors, network["host"] == "unknown" || !network["host"].empty?, "event.permission.network.host must be unknown or non-empty")
    if network["port"] == "unknown"
      # safe sentinel
    elsif network["port"].is_a?(Integer) && network["port"].between?(1, 65_535)
      # concrete port
    else
      errors << "event.permission.network.port must be integer 1..65535 or unknown"
    end
    expect_in(errors, network["operation"], NETWORK_OPERATIONS, "event.permission.network.operation")
    expect_string(errors, network["url"], "event.permission.network.url")
  end

  def validate_prompt(errors, prompt)
    expect_exact_fields(errors, prompt, PROMPT_FIELDS, "event.prompt")
    expect_string(errors, prompt["text"], "event.prompt.text") if prompt.is_a?(Hash)
  end

  def validate_assistant(errors, assistant)
    expect_exact_fields(errors, assistant, ASSISTANT_FIELDS, "event.assistant")
    expect_string(errors, assistant["last_message"], "event.assistant.last_message") if assistant.is_a?(Hash)
  end

  def validate_raw(errors, raw)
    expect_exact_fields(errors, raw, RAW_FIELDS, "event.raw")
    return unless raw.is_a?(Hash)

    expect_sha(errors, raw["payload_sha256"], "event.raw.payload_sha256")
    expect_string(errors, raw["event_name"], "event.raw.event_name")
    expect(errors, raw["logical_event_mismatch"] == false, "event.raw.logical_event_mismatch must be false for normalized trusted input")
    expect_string_array(errors, raw["provider_indicators"], "event.raw.provider_indicators")
  end

  def normalize_tool(payload, logical_event)
    tool_input = first_hash(payload, "tool_input", "tool", "input") || {}
    name = bounded_string(first_string(payload, "tool_name", "toolName", "name") || first_string(tool_input, "name", "tool_name"))
    kind = tool_kind(name)
    command = bounded_string(first_string(tool_input, "command", "cmd") || first_string(payload, "command"))
    patch = bounded_string(first_string(tool_input, "patch") || first_string(payload, "patch"))
    file_changes = file_changes_for(kind, tool_input, payload, patch)
    file_paths = file_changes.flat_map { |change| [change["old_path"], change["new_path"], change["path"]] }.reject(&:empty?).uniq.sort
    file_path = file_paths.first || bounded_string(first_string(tool_input, "file_path", "path") || first_string(payload, "file_path", "path"))
    file_paths = ([file_path] + file_paths).reject(&:empty?).uniq.sort
    {
      "name" => name,
      "kind" => kind,
      "write_intent" => write_intent_for(kind, logical_event, !name.empty?),
      "command" => command,
      "file_path" => file_path,
      "file_paths" => file_paths,
      "file_changes" => file_changes,
      "content" => bounded_string(first_string(tool_input, "content", "new_content")),
      "old_string" => bounded_string(first_string(tool_input, "old_string", "oldString")),
      "new_string" => bounded_string(first_string(tool_input, "new_string", "newString")),
      "patch" => patch
    }
  end

  def normalize_permission(payload, logical_event, tool)
    filesystem_payload = first_hash(payload, "filesystem", "fs") || {}
    permission_paths = logical_event == "permission-request" ? path_values(filesystem_payload, payload) : []
    requested_paths = if !tool.fetch("file_paths").empty?
                        tool.fetch("file_paths")
                      elsif !permission_paths.empty?
                        permission_paths
                      else
                        ["unknown"]
                      end
    operation = logical_event == "permission-request" ? permission_operation(payload, tool) : "unknown"
    access_mode = permission_access_mode(payload)
    filesystem = logical_event == "permission-request" ? normalize_permission_filesystem(payload, requested_paths, access_mode) : unknown_filesystem
    network = logical_event == "permission-request" ? normalize_permission_network(payload) : unknown_network
    {
      "request_id" => bounded_string(first_string(payload, "request_id", "id")),
      "operation" => operation,
      "access_mode" => access_mode,
      "requested_tool_kind" => logical_event == "permission-request" ? tool.fetch("kind") : "unknown",
      "requested_command" => logical_event == "permission-request" ? tool.fetch("command") : "",
      "requested_paths" => requested_paths,
      "filesystem" => filesystem,
      "network" => network,
      "can_approve" => can_approve(payload)
    }
  end

  def unknown_filesystem
    {
      "access_mode" => "unknown",
      "paths" => ["unknown"],
      "recursive" => "unknown",
      "scope" => "unknown"
    }
  end

  def unknown_network
    {
      "scheme" => "unknown",
      "host" => "unknown",
      "port" => "unknown",
      "operation" => "unknown",
      "url" => "unknown"
    }
  end

  def normalize_permission_filesystem(payload, requested_paths, top_access_mode)
    filesystem_payload = first_hash(payload, "filesystem", "fs") || {}
    raw_access = bounded_string(first_string(filesystem_payload, "access_mode", "accessMode") || top_access_mode).downcase
    access_mode = FILESYSTEM_ACCESS_MODES.include?(raw_access) ? raw_access : "unknown"
    paths = path_values(filesystem_payload, payload)
    paths = requested_paths if paths.empty? && requested_paths != ["unknown"]
    recursive = permission_recursive(filesystem_payload, payload)
    scope = permission_scope(filesystem_payload, payload)
    {
      "access_mode" => access_mode,
      "paths" => paths.empty? ? ["unknown"] : paths,
      "recursive" => recursive,
      "scope" => scope
    }
  end

  def normalize_permission_network(payload)
    network_payload = first_hash(payload, "network", "net") || {}
    url = bounded_string(first_string(network_payload, "url") || first_string(payload, "url"))
    parsed = parse_network_url(url)
    scheme = bounded_string(first_string(network_payload, "scheme") || first_string(payload, "scheme") || parsed.fetch("scheme")).downcase
    scheme = "unknown" unless NETWORK_SCHEMES.include?(scheme)
    host = bounded_string(first_string(network_payload, "host") || first_string(payload, "host") || parsed.fetch("host")).downcase
    host = "unknown" if host.empty?
    port = permission_port(network_payload, payload, parsed.fetch("port"))
    operation = bounded_string(first_string(network_payload, "operation") || first_string(payload, "network_operation") || parsed.fetch("operation")).downcase
    operation = "unknown" unless NETWORK_OPERATIONS.include?(operation)
    {
      "scheme" => scheme,
      "host" => host,
      "port" => port,
      "operation" => operation,
      "url" => url.empty? ? parsed.fetch("url") : url
    }
  end

  def file_changes_for(kind, tool_input, payload, patch)
    changes = []
    paths = path_values(tool_input, payload)
    case kind
    when "write"
      paths.each { |path| changes << change(path, "", path, "create", "payload") }
    when "edit", "multi-edit"
      paths.each { |path| changes << change(path, "", path, "modify", "payload") }
    when "patch"
      changes.concat(patch_changes(patch))
    end
    changes
  end

  def patch_changes(patch)
    return [] if patch.empty?

    changes = []
    patch.each_line do |line|
      case line
      when /\A\*\*\* Add File: (.+)\n?\z/
        path = Regexp.last_match(1).strip
        changes << change(path, "", path, "create", "patch")
      when /\A\*\*\* Update File: (.+)\n?\z/
        path = Regexp.last_match(1).strip
        changes << change(path, "", path, "modify", "patch")
      when /\A\*\*\* Move to: (.+)\n?\z/
        new_path = Regexp.last_match(1).strip
        previous = changes.last
        if previous && previous.fetch("action") == "modify" && previous.fetch("source") == "patch"
          old_path = previous.fetch("path")
          changes[-1] = change(new_path, old_path, new_path, "rename", "patch")
        end
      when /\A\*\*\* Delete File: (.+)\n?\z/
        path = Regexp.last_match(1).strip
        changes << change(path, path, "", "delete", "patch")
      end
    end
    changes.uniq
  end

  def change(path, old_path, new_path, action, source)
    {
      "path" => bounded_string(path),
      "old_path" => bounded_string(old_path),
      "new_path" => bounded_string(new_path),
      "action" => action,
      "source" => source
    }
  end

  def write_intent_for(kind, logical_event, has_tool)
    return "none" unless has_tool || logical_event == "permission-request"

    case kind
    when "write", "edit", "multi-edit", "patch"
      "write"
    when "read"
      "read"
    when "shell", "other", "unknown"
      "unknown"
    else
      "unknown"
    end
  end

  def tool_kind(name)
    return "unknown" if name.empty?

    TOOL_KIND_MAP.fetch(name.downcase, "other")
  end

  def permission_operation(payload, tool)
    raw = bounded_string(first_string(payload, "operation", "permission_operation")).downcase
    return raw if PERMISSION_OPERATIONS.include?(raw)

    case tool.fetch("kind")
    when "shell"
      "shell"
    when "write", "edit", "multi-edit", "patch"
      "write"
    when "unknown"
      "unknown"
    else
      "tool"
    end
  end

  def unknown_provider_tool(tool, logical_event)
    degraded = tool.merge(
      "kind" => "unknown",
      "file_path" => "",
      "file_paths" => [],
      "file_changes" => []
    )
    degraded["write_intent"] = logical_event == "permission-request" || !tool.fetch("name").empty? ? "unknown" : "none"
    degraded
  end

  def permission_access_mode(payload)
    raw = bounded_string(first_string(payload, "access_mode", "accessMode")).downcase
    ACCESS_MODES.include?(raw) ? raw : "unknown"
  end

  def permission_recursive(*hashes)
    raw = hashes.lazy.map { |hash| hash["recursive"] if hash.is_a?(Hash) }.find { |value| !value.nil? }
    return "true" if raw == true || raw == "true"
    return "false" if raw == false || raw == "false"

    "unknown"
  end

  def permission_scope(*hashes)
    raw = hashes.lazy.map { |hash| bounded_string(first_string(hash, "scope")).downcase if hash.is_a?(Hash) }.find { |value| !value.nil? && !value.empty? }
    FILESYSTEM_SCOPES.include?(raw) ? raw : "unknown"
  end

  def permission_port(network_payload, payload, parsed_port)
    raw = [network_payload["port"], payload["port"], parsed_port].find { |value| !value.nil? }
    return raw if raw.is_a?(Integer) && raw.between?(1, 65_535)

    "unknown"
  end

  def parse_network_url(raw_url)
    url = bounded_string(raw_url)
    return { "scheme" => "", "host" => "", "port" => nil, "operation" => "", "url" => "unknown" } if url.empty?

    uri = URI.parse(url)
    scheme = uri.scheme.to_s.downcase
    host = uri.host.to_s.downcase
    port = uri.port if %w[http https].include?(scheme) && !host.empty?
    operation = %w[http https].include?(scheme) && !host.empty? ? "connect" : ""
    { "scheme" => scheme, "host" => host, "port" => port, "operation" => operation, "url" => url }
  rescue URI::InvalidURIError
    { "scheme" => "", "host" => "", "port" => nil, "operation" => "", "url" => "unknown" }
  end

  def can_approve(payload)
    raw = payload["can_approve"] || payload["canApprove"] || payload["approval_capable"]
    return "true" if raw == true || raw == "true"
    return "false" if raw == false || raw == "false"

    "unknown"
  end

  def raw_event_name(payload, logical_event)
    bounded_string(first_string(payload, "hook_event_name", "hookEventName", "event", "type") || logical_event)
  end

  def native_logical_event(raw_event)
    NATIVE_EVENT_MAP.fetch(raw_event, LOGICAL_EVENTS.include?(raw_event) ? raw_event : "")
  end

  def provider_indicators(payload)
    indicators = []
    indicators << "claude.session_id" if payload.key?("session_id")
    indicators << "claude.transcript_path" if payload.key?("transcript_path")
    indicators << "claude.hook_event_name" if payload.key?("hook_event_name")
    indicators << "codex.thread_id" if payload.key?("thread_id") || payload.key?("conversation_id")
    indicators.uniq.sort
  end

  def first_hash(hash, *keys)
    keys.each do |key|
      value = hash[key]
      return value if value.is_a?(Hash)
    end
    nil
  end

  def first_string(hash, *keys)
    keys.each do |key|
      value = hash[key]
      return value if value.is_a?(String)
    end
    nil
  end

  def path_values(*hashes)
    hashes.flat_map do |hash|
      next [] unless hash.is_a?(Hash)

      single = first_string(hash, "file_path", "filePath", "path")
      arrays = %w[file_paths filePaths paths].flat_map do |key|
        value = hash[key]
        value.is_a?(Array) ? value.select { |item| item.is_a?(String) } : []
      end
      ([single] + arrays).compact.map { |path| bounded_string(path) }
    end.reject(&:empty?).uniq.sort
  end

  def bounded_string(value)
    value.to_s.byteslice(0, 65_536) || ""
  end

  def absolute_or_empty(value)
    value = bounded_string(value)
    return "" if value.empty?
    return "" if value.match?(/[\0\n\r]/)

    path = Pathname.new(value)
    path.absolute? ? path.cleanpath.to_s : ""
  end

  def normalize_identity_path(value, label)
    value = value.to_s
    raise "#{label} must be an absolute path" unless Pathname.new(value).absolute?
    raise "#{label} must not contain NUL or newline" if value.match?(/[\0\n\r]/)

    Pathname.new(value).cleanpath.to_s
  end

  def path_inside?(path, parent)
    path == parent || path.start_with?(parent.end_with?("/") ? parent : "#{parent}/")
  end

  def validate_identity_paths(errors, event)
    %w[cwd project_dir].each do |field|
      value = event[field]
      expect(errors, value.is_a?(String) && Pathname.new(value).absolute? && !value.match?(/[\0\n\r]/), "event.#{field} must be an absolute path without NUL/newline")
    end
    if event["cwd"].is_a?(String) && event["project_dir"].is_a?(String) && Pathname.new(event["cwd"]).absolute? && Pathname.new(event["project_dir"]).absolute?
      expect(errors, path_inside?(event["cwd"], event["project_dir"]), "event.cwd must be equal to or inside event.project_dir")
    end
    value = event["transcript_path"]
    expect(errors, value == "" || (value.is_a?(String) && Pathname.new(value).absolute?), "event.transcript_path must be absolute or empty")
  end

  def expect_exact_fields(errors, value, fields, label)
    unless value.is_a?(Hash)
      errors << "#{label} must be an object"
      return
    end
    errors << "#{label} fields must be exact" unless value.keys.sort == fields.sort
  end

  def expect_string(errors, value, label)
    errors << "#{label} must be a string" unless value.is_a?(String)
  end

  def expect_string_array(errors, value, label)
    unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      errors << "#{label} must be an array of strings"
    end
  end

  def expect_sha(errors, value, label)
    errors << "#{label} must be lowercase SHA-256" unless value.is_a?(String) && value.match?(/\A[a-f0-9]{64}\z/)
  end

  def expect_in(errors, value, allowed, label)
    errors << "#{label} must be one of #{allowed.join(", ")}" unless allowed.include?(value)
  end

  def expect(errors, condition, message)
    errors << message unless condition
  end
end
