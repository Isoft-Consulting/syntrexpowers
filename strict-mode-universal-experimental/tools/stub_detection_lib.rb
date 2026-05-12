# frozen_string_literal: true

require "digest"

module StrictModeStubDetection
  extend self

  # Расширения которые проверяем на stubs (как в v2.5 pre-write-scan.sh).
  SCANNABLE_EXTENSIONS = %w[php go js jsx ts tsx mjs cjs].freeze

  # Максимальный размер контента в байтах — большие правки не сканируем pre-write,
  # чтобы не тормозить hook. Stop-guard в будущем подберёт stubs из файла на диске.
  DEFAULT_MAX_BYTES = 524_288

  # Universal stub markers — применяются ко всем поддерживаемым расширениям.
  UNIVERSAL_PATTERNS = [
    { label: "TODO/FIXME/XXX/HACK", regex: /\b(TODO|FIXME|XXX|HACK)\b/ },
    {
      label: "later-marker",
      regex: /(дореал|доделат|допиш|потом сдела|реализу[ею] позже|implement later|fix later)/i
    }
  ].freeze

  # Per-extension patterns — language-specific stub idioms.
  # JS/TS family share one pattern list (объединяется ниже до freeze).
  _js_patterns = [
    {
      label: "js-not-implemented",
      regex: /throw\s+new\s+Error\([^)]*(not\s+implemented|TODO|stub|заглушк)/i
    }
  ].freeze

  EXTENSION_PATTERNS = {
    "php" => [
      {
        label: "php-not-implemented",
        regex: /throw\s+new\s+\\?[A-Za-z_]*Exception\([^)]*(not\s+implemented|заглушк|stub|todo)/i
      },
      {
        label: "php-die-stub",
        regex: /\bdie\([^)]*(stub|заглушк|todo|not\s+implemented)/i
      }
    ].freeze,
    "go" => [
      {
        label: "go-panic-stub",
        regex: /panic\(\s*"[^"]*(not\s+implemented|TODO|todo|stub|заглушк)/i
      },
      { label: "go-todo-marker", regex: %r{//\s*TODO[\(:]} }
    ].freeze,
    "js" => _js_patterns,
    "jsx" => _js_patterns,
    "ts" => _js_patterns,
    "tsx" => _js_patterns,
    "mjs" => _js_patterns,
    "cjs" => _js_patterns
  }.freeze

  # Allowlist directive types:
  #   finding <sha256>            — bypass by stripped-line-content hash
  #   path-line <path> <line-no>  — bypass by file path + line number (v2.5 style)
  # Plus blank lines and `#` comments are ignored.
  #
  # NOTE: per `specs/08-shared-core/01-stub-scan.md` Stub bypass safety section,
  # `allow-stub:` per-line markers are accepted ONLY when they existed in the
  # turn baseline. Pre-write hook has no baseline comparison available — by spec
  # we ignore `allow-stub:` markers entirely here. Honoring them would let an
  # agent trivially bypass stub-detection by adding `// allow-stub: x` to the
  # same line as their TODO. Baseline-aware `allow-stub:` enforcement is the
  # responsibility of a future Stop-time scanner (compares files-on-disk vs the
  # turn-start baseline). The hash-allowlist path (`finding <sha256>` in
  # stub-allowlist.txt) is still honored because that file is protected config:
  # an agent cannot mutate it within the turn, so its entries are guaranteed to
  # exist in the turn baseline by the protected-baseline contract.

  # Возвращает array of findings; пустой если код чистый или hash-allowlisted.
  # Каждая finding: {label, line_number, line_content, line_sha256}
  def scan(content:, file_path:, allowlist: { hashes: [], path_lines: [] }, max_bytes: DEFAULT_MAX_BYTES)
    return [] if content.nil? || content.empty?
    return [] if content.bytesize > max_bytes

    extension = extension_for(file_path)
    return [] unless scannable?(extension)

    patterns = UNIVERSAL_PATTERNS + (EXTENSION_PATTERNS[extension] || [])
    findings = []

    content.each_line.with_index(1) do |raw_line, line_number|
      line = raw_line.chomp

      patterns.each do |pattern|
        next unless pattern.fetch(:regex).match?(line)

        line_hash = stripped_line_sha256(line)
        next if allowlist.fetch(:hashes, []).include?(line_hash)
        next if allowlist.fetch(:path_lines, []).include?([file_path, line_number])

        findings << {
          "label" => pattern.fetch(:label),
          "line_number" => line_number,
          "line_content" => line,
          "line_sha256" => line_hash,
          "file_path" => file_path
        }
      end
    end

    findings
  end

  # Извлекает все scannable file_path → content пары из normalized tool.
  # Kind-based (не name-based) extraction — закрывает случай когда новый
  # write-tool с незнакомым именем имеет kind="write"/"edit" но stub-detection
  # его пропускал из-за case-by-name. Подход: смотрим в "content" для write-kind
  # и в "new_string" для edit-kind, независимо от имени. MultiEdit/apply_patch
  # содержат per-edit content только в raw tool_input — для них caller должен
  # вызывать extract_raw_targets отдельно.
  def extract_scannable_targets(tool)
    kind = tool.fetch("kind", "").to_s
    file_path = tool.fetch("file_path", "").to_s

    case kind
    when "write"
      content = tool.fetch("content", "").to_s
      return [] if file_path.empty? || content.empty?

      [{ "file_path" => file_path, "content" => content }]
    when "edit"
      content = tool.fetch("new_string", "").to_s
      return [] if file_path.empty? || content.empty?

      [{ "file_path" => file_path, "content" => content }]
    else
      []
    end
  end

  # Извлекает per-change content из СЫРОГО tool_input (до нормализации).
  # Kind-based dispatch чтобы новые tool names с `kind="multi-edit"` или
  # `kind="patch"` тоже сканировались (closes gap паралleлый
  # extract_scannable_targets fix). Для совместимости с тестами / legacy кодом
  # сигнатура принимает либо normalized tool Hash, либо строку имени (старый
  # API). Hash тип имеет приоритет: реальный pre-tool-use поток передаёт
  # normalized tool через bin/strict-hook, имя — только тесты.
  def extract_raw_targets(tool_or_name, raw_tool_input)
    return [] unless raw_tool_input.is_a?(Hash)

    kind, name = if tool_or_name.is_a?(Hash)
                   [tool_or_name.fetch("kind", "").to_s, tool_or_name.fetch("name", "").to_s]
                 elsif tool_or_name.is_a?(String)
                   ["", tool_or_name]
                 else
                   return []
                 end

    case kind
    when "multi-edit"
      return extract_multi_edit_targets(raw_tool_input)
    when "patch"
      return extract_apply_patch_targets(raw_tool_input)
    end

    case name
    when "MultiEdit"
      extract_multi_edit_targets(raw_tool_input)
    when "ApplyPatch", "apply_patch"
      extract_apply_patch_targets(raw_tool_input)
    else
      []
    end
  end

  private

  def extract_multi_edit_targets(tool_input)
    file_path = (tool_input["file_path"] || tool_input["filePath"] || "").to_s
    return [] if file_path.empty?

    edits = tool_input["edits"]
    return [] unless edits.is_a?(Array)

    # Один target ПЕР edit: каждое new_string сканируется отдельно, line_number в
    # finding report считается относительно начала ЭТОГО new_string'а (line 1 =
    # первая строка edit's new_string). Раньше делали joined content через "\n",
    # из-за чего line_number у findings во втором edit врал (был сдвинут на
    # сумму строк предыдущих edit'ов). Per-edit разделение даёт точные позиции
    # и cleaner semantics: каждое edit — отдельный логический write event.
    edits.each_with_object([]) do |edit, targets|
      next unless edit.is_a?(Hash)

      content = (edit["new_string"] || edit["newString"] || "").to_s
      next if content.empty?

      targets << { "file_path" => file_path, "content" => content }
    end
  end

  def extract_apply_patch_targets(tool_input)
    patch = (tool_input["patch"] || tool_input["body"] || "").to_s
    return [] if patch.empty?

    targets = []
    current_path = nil
    current_buffer = []

    flush = lambda do
      next if current_path.nil? || current_path.empty? || current_buffer.empty?

      content = current_buffer.join
      targets << { "file_path" => current_path, "content" => content } unless content.empty?
    end

    patch.each_line do |line|
      case line
      when /\A\*\*\* (Add|Update) File: (.+)\n?\z/
        flush.call
        current_path = Regexp.last_match(2).strip
        current_buffer = []
      when /\A\*\*\* Move to: (.+)\n?\z/
        # Move меняет путь файла, content под Update block отражает состояние
        # ПОСЛЕ переименования. Сохраняем накопленный buffer, переписываем
        # current_path на новое значение — flush на следующем block boundary
        # выдаст target с НОВЫМ path. Раньше Move обнулял path → content
        # терялся в неправильную сторону (atributed к old path до flush, без
        # учёта что Move "переадресует" content к new path).
        current_path = Regexp.last_match(1).strip if current_path
      when /\A\*\*\* (Delete File|End Patch)/
        flush.call
        current_path = nil
        current_buffer = []
      when /\A\+(.*)\z/m
        # Только added lines участвуют в новой версии содержимого.
        current_buffer << (Regexp.last_match(1) || "") if current_path
      end
    end
    flush.call

    targets
  end

  public

  # Парсит stub-allowlist.txt протектед-конфиг файл. Принимает массив директив
  # как из StrictModeProtectedConfig.load_records (формат `finding <sha256>`),
  # возвращает hashed lookup таблицу для быстрого membership check'а в scan().
  # path_lines резервируется на будущее расширение (v2.5-style path:line bypass).
  def parse_allowlist_records(records)
    hashes = []
    path_lines = []
    records.each do |record|
      directive = record.fetch("directive", "")
      case directive
      when "finding"
        hashes << record.fetch("finding_digest")
      end
    end
    { hashes: hashes.uniq, path_lines: path_lines }
  end

  private

  def extension_for(file_path)
    return "" unless file_path.is_a?(String) && !file_path.empty?

    dot = file_path.rindex(".")
    return "" if dot.nil? || dot == file_path.length - 1

    file_path[(dot + 1)..].downcase
  end

  def scannable?(extension)
    SCANNABLE_EXTENSIONS.include?(extension)
  end

  def stripped_line_sha256(line)
    Digest::SHA256.hexdigest(line.strip)
  end
end
