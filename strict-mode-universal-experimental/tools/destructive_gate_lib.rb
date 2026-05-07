#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module StrictModeDestructiveGate
  extend self

  WRITE_TOOL_KINDS = %w[write edit multi-edit patch].freeze
  PATH_BEARING_KINDS = (WRITE_TOOL_KINDS + %w[other unknown]).freeze
  SHELL_MUTATORS = %w[
    rm mv cp chmod chown chgrp truncate tee ln mkdir rmdir install touch dd rsync tar zip unzip
  ].freeze
  REDIRECT_OPS = %w[> >> 1> 1>> 2> 2>> &> &>>].freeze
  MAX_SUBSTITUTION_DEPTH = 8

  def classify_tool(tool, cwd:, project_dir:, protected_roots:, protected_inodes: [], destructive_patterns: [], home: Dir.home, install_root: nil)
    errors = []
    cwd_path = normalize_identity_path(cwd, "cwd", errors)
    project_path = normalize_identity_path(project_dir, "project_dir", errors)
    return block("invalid-identity", errors.join("; ")) unless errors.empty?
    return block("invalid-identity", "cwd must be equal to or inside project_dir") unless path_inside?(cwd_path, project_path)

    kind = tool.fetch("kind", "unknown").to_s
    return classify_shell(tool, cwd: cwd_path, project_dir: project_path, protected_roots: protected_roots, protected_inodes: protected_inodes, destructive_patterns: destructive_patterns, home: home, install_root: install_root) if kind == "shell"
    return allow("non-write-tool") unless write_like_tool?(tool)

    classify_direct_paths(tool, cwd: cwd_path, protected_roots: protected_roots, protected_inodes: protected_inodes)
  end

  def classify_shell(tool, cwd:, project_dir:, protected_roots:, protected_inodes:, destructive_patterns:, home:, install_root:, substitution_depth: 0)
    command = tool.fetch("command", "").to_s
    return block("shell-command-missing", "shell command is empty") if command.empty?

    tokens = shell_tokens(command)
    return block("shell-parse-error", tokens.fetch("error")) if tokens.fetch("error")

    words = tokens.fetch("words")
    return block("shell-command-missing", "shell command has no argv words") if words.empty?
    substitution_result = classify_shell_substitutions(
      command,
      cwd: cwd,
      project_dir: project_dir,
      protected_roots: protected_roots,
      protected_inodes: protected_inodes,
      destructive_patterns: destructive_patterns,
      home: home,
      install_root: install_root,
      substitution_depth: substitution_depth
    )
    return substitution_result if substitution_result

    import_result = classify_strict_fdr_import(words, tokens, cwd: cwd, project_dir: project_dir, protected_roots: protected_roots, protected_inodes: protected_inodes, install_root: install_root)
    return import_result if import_result

    runtime_execution = runtime_executable_execution(tokens, protected_roots, cwd)
    return block("protected-runtime-execution", runtime_execution) if runtime_execution

    destructive = destructive_match(command, words, destructive_patterns)
    return block("destructive-command", destructive) if destructive

    write_info = shell_write_info(words, tokens)
    protected_mentions = protected_path_mentions(words, cwd, home, protected_roots, protected_inodes, allow_bare: false)
    protected_mentions += protected_path_mentions(tokens.fetch("redirect_targets") + write_info.fetch("known_targets"), cwd, home, protected_roots, protected_inodes, allow_bare: true)
    if protected_mentions.any? && write_info.fetch("write_capable")
      return block("protected-root", "write-capable shell command mentions protected path #{protected_mentions.first}")
    end
    if write_info.fetch("unknown_write_targets")
      return block("unknown-write-target", write_info.fetch("reason"))
    end

    allow("shell-read-only-or-unmatched")
  end

  def classify_direct_paths(tool, cwd:, protected_roots:, protected_inodes:)
    paths = Array(tool["file_paths"])
    paths = [tool["file_path"]] if paths.empty? && tool["file_path"].is_a?(String)
    paths = paths.compact.map(&:to_s).reject(&:empty?)
    return block("protected-target-unknown", "write-like tool did not expose target paths") if paths.empty? || paths.include?("unknown")

    paths.each do |raw|
      normalized = normalize_tool_path(raw, cwd)
      return block("protected-target-unknown", "target path #{raw.inspect} is not normalizable") unless normalized
      normalized_path = Pathname.new(normalized)
      return block("protected-root", "target path #{normalized} is under protected root") if protected_roots.any? { |root| path_inside?(normalized, root.to_s) }
      return block("protected-root", "target path #{normalized} has symlink parent component") if symlink_parent_component?(normalized_path)
      return block("protected-root", "target path #{normalized} has symlink final component") if normalized_path.symlink?
      return block("protected-root", "target path #{normalized} matches protected dev+inode") if protected_inode_path?(normalized_path, protected_inodes)
    end

    allow("write-targets-disjoint")
  end

  def write_like_tool?(tool)
    kind = tool.fetch("kind", "unknown").to_s
    write_intent = tool.fetch("write_intent", "unknown").to_s
    return true if WRITE_TOOL_KINDS.include?(kind)
    return true if PATH_BEARING_KINDS.include?(kind) && write_intent != "read"

    false
  end

  def shell_tokens(command)
    words = []
    ops = []
    redirect_targets = []
    items = []
    token = +""
    quote = nil
    pending_redirect = false
    i = 0
    while i < command.length
      char = command[i]
      if quote
        if char == quote
          quote = nil
        elsif quote == '"' && char == "\\"
          i += 1
          return token_error("trailing escape in double quote") if i >= command.length

          token << command[i]
        else
          token << char
        end
      elsif char == "'" || char == '"'
        quote = char
      elsif char == "\\"
        i += 1
        return token_error("trailing escape") if i >= command.length

        token << command[i]
      elsif char.match?(/\s/)
        flushed = push_word(words, items, token)
        if pending_redirect && flushed
          redirect_targets << flushed
          pending_redirect = false
        end
      elsif (op = shell_operator_at(command, i))
        flushed = push_word(words, items, token)
        if pending_redirect && flushed
          redirect_targets << flushed
          pending_redirect = false
        end
        return token_error("redirect operator missing target") if pending_redirect

        ops << op
        items << { "type" => "op", "value" => op }
        pending_redirect = true if REDIRECT_OPS.include?(op)
        i += op.length - 1
      else
        token << char
      end
      i += 1
    end
    return token_error("unterminated #{quote} quote") if quote

    flushed = push_word(words, items, token)
    if pending_redirect && flushed
      redirect_targets << flushed
      pending_redirect = false
    end
    return token_error("redirect operator missing target") if pending_redirect

    { "words" => words.reject { |word| REDIRECT_OPS.include?(word) }, "ops" => ops, "redirect_targets" => redirect_targets, "items" => items, "error" => nil }
  end

  def shell_operator_at(command, index)
    return nil unless command[index]

    %w[&>> >> 2>> 1>> && || &> 2> 1> << > < | & ;].find { |op| command[index, op.length] == op }
  end

  def flush_word(words, token)
    return nil if token.empty?

    flushed = token.dup
    words << flushed
    token.clear
    flushed
  end

  def push_word(words, items, token)
    flushed = flush_word(words, token)
    items << { "type" => "word", "value" => flushed } if flushed
    flushed
  end

  def token_error(message)
    { "words" => [], "ops" => [], "redirect_targets" => [], "items" => [], "error" => message }
  end

  def classify_shell_substitutions(command, cwd:, project_dir:, protected_roots:, protected_inodes:, destructive_patterns:, home:, install_root:, substitution_depth:)
    fragments = shell_substitution_fragments(command)
    return nil if fragments.empty?
    return block("unknown-write-target", "shell substitution nesting exceeds classifier limit") if substitution_depth >= MAX_SUBSTITUTION_DEPTH

    fragments.each do |fragment|
      inner_command = shell_substitution_body(fragment).strip
      next if inner_command.empty?

      result = classify_shell(
        { "kind" => "shell", "command" => inner_command },
        cwd: cwd,
        project_dir: project_dir,
        protected_roots: protected_roots,
        protected_inodes: protected_inodes,
        destructive_patterns: destructive_patterns,
        home: home,
        install_root: install_root,
        substitution_depth: substitution_depth + 1
      )
      next unless result.fetch("decision") == "block"

      reason = result.fetch("reason").to_s
      detail = reason.empty? ? result.fetch("reason_code") : "#{result.fetch("reason_code")}: #{reason}"
      return block(result.fetch("reason_code"), "shell substitution would block: #{detail}")
    end
    nil
  end

  def destructive_match(command, words, destructive_patterns)
    destructive_patterns.each do |record|
      case record["directive"]
      when "shell-ere"
        pattern = record["pattern"].to_s
        return "shell-ere #{pattern}" if Regexp.new(pattern).match?(command)
      when "argv-token"
        token = record["token"].to_s
        return "argv-token #{token}" if words.include?(token)
      end
    end
    nil
  rescue RegexpError => e
    "invalid shell-ere pattern: #{e.message}"
  end

  def shell_write_info(_words, tokens)
    segments = effective_shell_segments(tokens)
    executable_segments = segments.map do |segment|
      executable = shell_executable_word(segment)
      executable ? [File.basename(executable), segment] : nil
    end.compact
    executable_names = executable_segments.map(&:first)
    inline_runner = executable_segments.any? { |executable, segment| inline_write_interpreter?(executable, segment) }
    package_runner = executable_segments.any? { |executable, segment| package_or_script_runner?(executable, segment) }
    wrapper_runner = executable_segments.any? { |executable, segment| shell_wrapper_unknown_runner?(executable, segment) }
    write_capable = tokens.fetch("ops").any? { |op| REDIRECT_OPS.include?(op) } || tokens.fetch("redirect_targets").any?
    write_capable ||= executable_names.any? { |executable| SHELL_MUTATORS.include?(executable) }
    write_capable ||= inline_runner
    write_capable ||= package_runner
    write_capable ||= wrapper_runner
    return { "write_capable" => write_capable, "unknown_write_targets" => false, "reason" => "", "known_targets" => [] } unless write_capable

    known_targets = known_shell_targets(tokens)
    dynamic_targets = known_targets.select { |target| dynamic_shell_target?(target) }
    unknown = known_targets.empty? || inline_runner || package_runner || wrapper_runner || dynamic_targets.any?
    {
      "write_capable" => true,
      "unknown_write_targets" => unknown,
      "reason" => unknown ? shell_unknown_write_reason(known_targets, dynamic_targets) : "",
      "known_targets" => known_targets
    }
  end

  def shell_unknown_write_reason(known_targets, dynamic_targets)
    return "write-capable shell command has no statically proven target set" if known_targets.empty?
    return "write-capable shell command has dynamic target #{dynamic_targets.first.inspect}" if dynamic_targets.any?

    "write-capable shell command has unproven target set"
  end

  def dynamic_shell_target?(word)
    return false if static_home_expansion?(word)

    word.include?("`") ||
      word.include?("$(") ||
      word.include?("<(") ||
      word.include?(">(") ||
      word.match?(/\$[A-Za-z_][A-Za-z0-9_]*/) ||
      word.match?(/[*?\[\]{}]/)
  end

  def static_home_expansion?(word)
    word == "$HOME" ||
      word.start_with?("$HOME/") ||
      word == "${HOME}" ||
      word.start_with?("${HOME}/")
  end

  def inline_write_interpreter?(executable, words)
    case executable
    when "python", "python3", "node", "ruby"
      words.include?("-c") || words.include?("-e")
    when "php"
      words.include?("-r")
    when "perl"
      words.any? { |word| word.start_with?("-pi") }
    when "sed"
      words.include?("-i") || words.any? { |word| word.start_with?("-i") }
    else
      false
    end
  end

  def package_or_script_runner?(executable, words)
    return true if %w[npm yarn pnpm pip pip3 gem bundle composer cargo go make cmake ninja].include?(executable)
    return true if %w[sh bash zsh fish].include?(executable) && words.length > 1

    false
  end

  def shell_wrapper_unknown_runner?(executable, words)
    return true if executable == "xargs" && words.length > 1
    return true if executable == "find" && words.any? { |word| %w[-delete -exec -execdir].include?(word) }

    false
  end

  def known_shell_targets(tokens)
    targets = tokens.fetch("redirect_targets").dup
    effective_shell_segments(tokens).each do |segment|
      executable = shell_executable_word(segment)
      next unless executable

      executable_index = segment.index(executable)
      next unless executable_index

      executable_name = File.basename(executable)
      next unless SHELL_MUTATORS.include?(executable_name)

      args = segment[(executable_index + 1)..] || []
      targets.concat(shell_mutator_targets(executable_name, args))
    end
    targets
  end

  def shell_mutator_targets(executable_name, args)
    case executable_name
    when "dd"
      args.select { |word| word.start_with?("of=") }.map { |word| word.delete_prefix("of=") }.reject(&:empty?)
    else
      args.reject { |word| env_assignment?(word) || word.start_with?("-") }
    end
  end

  def protected_path_mentions(words, cwd, home, protected_roots, protected_inodes, allow_bare:)
    words.map do |word|
      normalized = shell_path_word(word, cwd, home, allow_bare: allow_bare)
      next unless normalized
      path = Pathname.new(normalized)
      if protected_roots.any? { |root| path_inside?(normalized, root.to_s) } ||
         symlink_parent_component?(path) ||
         path.symlink? ||
         protected_inode_path?(path, protected_inodes)
        normalized
      end
    end.compact
  end

  def shell_path_word(word, cwd, home, allow_bare: false)
    expanded = case word
               when "~"
                 home.to_s
               when /\A~\//
                 File.join(home.to_s, word[2..])
               when /\A\$HOME(?:\/|\z)/
                 File.join(home.to_s, word.delete_prefix("$HOME").delete_prefix("/"))
               when /\A\$\{HOME\}(?:\/|\z)/
                 File.join(home.to_s, word.delete_prefix("${HOME}").delete_prefix("/"))
               else
                 word
    end
    return Pathname.new(expanded).cleanpath.to_s if expanded.start_with?("/")
    return cwd.join(expanded).cleanpath.to_s if expanded.include?("/") || expanded.start_with?(".")
    return cwd.join(expanded).cleanpath.to_s if allow_bare

    nil
  rescue ArgumentError
    nil
  end

  def normalize_tool_path(raw, cwd)
    path = Pathname.new(raw)
    normalized = path.absolute? ? path.cleanpath : cwd.join(path).cleanpath
    normalized.to_s
  rescue ArgumentError
    nil
  end

  def classify_strict_fdr_import(words, tokens, cwd:, project_dir:, protected_roots:, protected_inodes:, install_root:)
    return nil unless words.length == 4 && words[1] == "import" && words[2] == "--"
    return nil unless install_root

    strict_fdr = Pathname.new(install_root).join("active/bin/strict-fdr").cleanpath.to_s
    executable = normalize_tool_path(words[0], cwd)
    return nil unless executable == strict_fdr

    return block("trusted-import-invalid", "strict-fdr import command must not contain shell operators") unless tokens.fetch("ops").empty?

    source = normalize_tool_path(words[3], cwd)
    return block("trusted-import-invalid", "source path is not normalizable") unless source
    source_path = Pathname.new(source)
    return block("trusted-import-invalid", "source path must be inside project") unless path_inside?(source, project_dir)
    return block("trusted-import-invalid", "source path must be outside protected roots") if protected_roots.any? { |root| path_inside?(source, root.to_s) }
    return block("trusted-import-invalid", "source path has symlink component") if symlink_parent_component?(source_path)
    return block("trusted-import-invalid", "source path must be an existing regular file") unless source_path.file? && !source_path.symlink?
    return block("trusted-import-invalid", "source path matches protected dev+inode") if protected_inode_path?(source_path, protected_inodes)

    allow("trusted-fdr-import", "trusted_import_source" => source)
  end

  def runtime_executable_execution(tokens, protected_roots, cwd)
    shell_executable_words(tokens).each do |executable_word|
      executable = normalize_tool_path(executable_word, cwd)
      next unless executable

      protected_roots.each do |root|
        root_path = Pathname.new(root).cleanpath.to_s
        next unless path_inside?(executable, root_path)

        description = runtime_path_description(executable)
        return description if description
      end
    end
    nil
  end

  def runtime_path_description(path)
    basename = File.basename(path)
    return "runtime executable #{path}" if basename.start_with?("strict-") || %w[install.sh uninstall.sh rollback.sh].include?(basename)
    return "runtime script #{path}" if path.include?("/core/") || path.include?("/lib/") || path.include?("/providers/")

    nil
  end

  def shell_substitution_body(fragment)
    if fragment.start_with?("`")
      body = fragment[1..] || ""
      return body.end_with?("`") ? body[0...-1] : body
    end

    body = fragment[2..] || ""
    body.end_with?(")") ? body[0...-1] : body
  end

  def shell_substitution_fragments(command)
    fragments = []
    quote = nil
    i = 0
    while i < command.length
      char = command[i]
      if quote == "'"
        quote = nil if char == "'"
      else
        if char == "\\" && quote == '"'
          i += 1
        elsif char == '"'
          quote = quote == '"' ? nil : '"'
        elsif substitution_start_at?(command, i)
          finish = find_substitution_end(command, i)
          fragments << command[i..finish]
          i = finish
        elsif char == "`"
          finish = find_backtick_end(command, i)
          fragments << command[i..finish]
          i = finish
        elsif char == "'"
          quote = "'"
        elsif char == "\\"
          i += 1
        end
      end
      i += 1
    end
    fragments
  end

  def substitution_start_at?(command, index)
    %w[$( <( >(].any? { |marker| command[index, marker.length] == marker }
  end

  def find_substitution_end(command, start_index)
    open_index = start_index + 1
    depth = 1
    quote = nil
    i = open_index + 1
    while i < command.length
      char = command[i]
      if quote == "'"
        quote = nil if char == "'"
      elsif quote == '"'
        if char == "\\"
          i += 1
        elsif char == '"'
          quote = nil
        elsif substitution_start_at?(command, i)
          depth += 1
          i += 1
        elsif char == ")"
          depth -= 1
          return i if depth.zero?
        end
      elsif char == "'"
        quote = "'"
      elsif char == '"'
        quote = '"'
      elsif char == "\\"
        i += 1
      elsif substitution_start_at?(command, i)
        depth += 1
        i += 1
      elsif char == ")"
        depth -= 1
        return i if depth.zero?
      end
      i += 1
    end
    command.length - 1
  end

  def find_backtick_end(command, start_index)
    i = start_index + 1
    while i < command.length
      char = command[i]
      if char == "\\"
        i += 1
      elsif char == "`"
        return i
      end
      i += 1
    end
    command.length - 1
  end

  def shell_segments(tokens)
    segments = [[]]
    tokens.fetch("items", []).each do |item|
      if item.fetch("type") == "op" && command_separator?(item.fetch("value"))
        segments << []
      elsif item.fetch("type") == "word"
        segments.last << item.fetch("value")
      end
    end
    segments.reject(&:empty?)
  end

  def effective_shell_segments(tokens)
    segments = shell_segments(tokens)
    segments + segments.map { |segment| wrapper_nested_segment(segment) }.compact
  end

  def wrapper_nested_segment(segment)
    executable = shell_executable_word(segment)
    return nil unless executable

    executable_index = segment.index(executable)
    return nil unless executable_index

    executable_name = File.basename(executable)
    case executable_name
    when "env"
      nested = segment[(executable_index + 1)..] || []
      nested = nested.drop_while { |word| env_assignment?(word) || word.start_with?("-") }
      nested.empty? ? nil : nested
    when "sudo", "command"
      nested = segment[(executable_index + 1)..] || []
      nested = nested.drop_while { |word| word.start_with?("-") || env_assignment?(word) }
      nested.empty? ? nil : nested
    else
      nil
    end
  end

  def command_separator?(op)
    %w[| || & && ;].include?(op)
  end

  def shell_executable_words(tokens)
    effective_shell_segments(tokens).map { |segment| shell_executable_word(segment) }.compact
  end

  def shell_executable_word(words)
    words.find { |word| !env_assignment?(word) }
  end

  def env_assignment?(word)
    word.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
  end

  def normalize_identity_path(path, field, errors)
    normalized = Pathname.new(path.to_s).expand_path.cleanpath
    errors << "#{field} must be absolute" unless normalized.absolute?
    normalized
  rescue ArgumentError
    errors << "#{field} is not normalizable"
    Pathname.new("/")
  end

  def path_inside?(path, root)
    clean_path = Pathname.new(path.to_s).cleanpath.to_s
    clean_root = Pathname.new(root.to_s).cleanpath.to_s
    clean_path == clean_root || clean_path.start_with?("#{clean_root}/")
  end

  def symlink_parent_component?(path)
    current = Pathname.new("/")
    parts = path.each_filename.to_a
    parts[0...-1].any? do |part|
      current = current.join(part)
      current.symlink?
    end
  end

  def protected_inode_path?(path, protected_inodes)
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

  def allow(reason_code, extra = {})
    { "decision" => "allow", "reason_code" => reason_code, "reason" => "", "metadata" => extra }
  end

  def block(reason_code, reason)
    { "decision" => "block", "reason_code" => reason_code, "reason" => reason, "metadata" => {} }
  end
end
