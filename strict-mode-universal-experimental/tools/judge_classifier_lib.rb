# frozen_string_literal: true

module StrictModeJudgeClassifier
  FIRST_CYCLE_GAP = "Где ты схалтурил? Перечисли конкретно: что упростил, что пропустил, что оставил недоделанным, какие edge cases не проверил."
  DENIAL_GAP = "Не верю. Где ты схалтурил? Перечисли что упростил, пропустил, не доделал, какие edge cases пропустил. Если действительно ничего — объясни какие конкретно vulnerable spots ты проверил вручную и почему уверен что они clean."
  DISMISSIVE_GAP = "Эти 'мелочи'/'не критично' — подозрительная формулировка. Перечисли каждое такое item конкретно: что именно осталось, почему ты считаешь это minor, и фикси если оно in scope. Если out-of-scope — обоснуй."
  FIX_GAP = "Давай исправлять. Конкретно перечисли in-scope items без out-of-scope обоснования и исправь их кодом."
  REPEAT_GAP = "Ты уже перечислял эти items в прошлом cycle. Либо фикси либо обоснуй out-of-scope явно для каждого."
  REVIEW_GAP = "Review-mode: не переходи к fix-cycle. Дай более конкретные findings: file/symbol, severity, harm, next verification surface."

  OUT_OF_SCOPE_RE = /
    вне\s+(?:текущего\s+)?scope|
    out\s+of\s+(?:current\s+)?scope|
    следующ(?:ем|ий|ая)\s+(?:pr|пр|коммит|задач)|
    follow[- ]?up|
    избыточно\s+для\s+этой\s+задачи|
    явно\s+не\s+входит|
    by\s+design|
    по\s+дизайну|
    пользователь\s+явно\s+сказал\s+не\s+делать
  /ix.freeze

  CUT_CORNER_RE = /
    схалтур|
    упростил|
    пропустил|
    не\s+проверил|
    не\s+доделал|
    оставил\s+недодел|
    edge\s+cases?|
    cut\s+corners?|
    skipped|
    missed|
    did\s+not\s+test|
    not\s+tested|
    left\s+undone
  /ix.freeze

  DENIAL_RE = /
    не\s+схалтурил|
    ничего\s+не\s+схалтурил|
    нет\s+халтуры|
    0\s*проблем|
    0\s+(?:issues?|problems?|findings?)|
    no\s+(?:issues|findings|problems)\s+found|
    nothing\s+to\s+(?:fix|address)|
    all\s+clean|
    всё\s+чисто|
    все\s+чисто
  /ix.freeze

  DISMISSIVE_RE = /
    почти|
    мелоч[ьи]|
    не\s+критичн|
    некритичн|
    минор|
    minor|
    polish\s+only|
    ship\s+anyway|
    достаточно|
    не\s+важно|
    неважно
  /ix.freeze

  REVIEW_POSITIVE_RE = /
    \/fdr\b|
    \/review\b|
    code\s+review|
    review[- ]only|
    no\s+fixes|
    just\s+(?:review|check)|
    (?:проведи|посмотри|проверь|сделай)[^.!?\n]{0,80}(?:фдр|fdr|ревью|review|пр|pr|пулл|pull)|
    (?:фдр|fdr|ревью|review|аудит|audit)
  /ix.freeze

  FIX_INTENT_RE = /
    фикси|
    фиксить|
    исправь|
    исправляй|
    правь|
    почини|
    сделай\s+правк|
    \bfix(?:es|ing)?\b|
    \bpatch\b|
    \bimplement\b
  /ix.freeze

  VERDICT_RE = /
    0\s*проблем|
    0\s+(?:[[:alpha:]]+\s+)?(?:issues?|problems?|findings?)|
    ready\s+to\s+merge|
    verdict[^.]{0,80}(?:ready|clean|0\s+(?:open|problems|проблем))|
    no\s+(?:issues|findings|problems)\s+found|
    (?:found|нашёл)\s+(?:nothing|ничего)|
    (?:all|всё|все)\s+(?:clean|clear|ok|чисто)|
    выглядит\s+(?:хорошо|отлично|чисто|нормально)|
    (?:nothing|none)\s+(?:to\s+(?:fix|address)|critical)|
    [0-9]+\s+(?:findings?|issues?|problems?|замечани[йя])\s+(?:closed|resolved|fixed|устранен|закрыт|закрыто|исправлен)|
    (?:all|всё|все|every)\s+(?:findings?|issues?|problems?|замечани[йя])\s+(?:closed|resolved|fixed|закрыт|закрыто|устранен)|
    (?:everything|всё)\s+(?:closed|resolved|fixed|done|completed|устранен|исправлен|закрыт|закрыто)|
    (?:verdict|итог|status)[^.]{0,40}(?:complete|completed|done|finished|закончен|завершен)|
    (?:FDR|ФДР|review|ревью)\s*[=:]\s*0\b
  /ix.freeze

  SEVERITY_ZERO_PAIR_RE = /
    (?:
      0\s*(?:critical|crit|критичн\w*)[^[:alnum:]]{0,40}0\s*(?:high|высок\w*|major)|
      0\s*(?:high|высок\w*|major)[^[:alnum:]]{0,40}0\s*(?:critical|crit|критичн\w*)|
      (?:critical|crit|критичн\w*)\s*[:=]\s*0[^[:alnum:]]{0,40}(?:high|высок\w*|major)\s*[:=]\s*0|
      (?:high|высок\w*|major)\s*[:=]\s*0[^[:alnum:]]{0,40}(?:critical|crit|критичн\w*)\s*[:=]\s*0
    )
  /ix.freeze

  module_function

  def classify(input)
    return unknown("parse-failure", "judge input is not a JSON object") unless input.is_a?(Hash)

    current = string_field(input, "current_response")
    return unknown("parse-failure", "empty current_response") if current.strip.empty?

    history = array_field(input, "history")
    review_mode = explicit_review_mode?(input) ? booleanish(input["review_mode"]) : review_mode_from_user_message(string_field(input, "last_user_msg"))
    matched_verdict = verdict_match(current)

    return challenge("substantive", [REVIEW_GAP], "review-mode requires concrete findings, not fix instructions", "0.720") if review_mode && review_needs_more_findings?(current)
    return challenge("substantive", [FIRST_CYCLE_GAP], "Cycle 1: trigger the cut-corners question", "0.900") if first_response_cycle?(history)

    return challenge("evasive", [DISMISSIVE_GAP], "dismissive халтура marker detected", "0.820") if current.match?(DISMISSIVE_RE)
    return challenge("repetitive", [REPEAT_GAP], "current response repeats the previous judge cycle", "0.780") if repetitive?(current, history)

    if current.match?(CUT_CORNER_RE)
      return clean("Agent listed cut corners with explicit out-of-scope justification.", "0.760") if current.match?(OUT_OF_SCOPE_RE)

      return challenge("substantive", [FIX_GAP], "cut-corner admission lacks out-of-scope justification", "0.830")
    end

    if matched_verdict || current.match?(DENIAL_RE)
      return challenge("evasive", [DENIAL_GAP], "agent asserted a clean verdict instead of answering where it cut corners", "0.810")
    end

    challenge("evasive", [DENIAL_GAP], "response does not answer the cut-corners challenge", "0.640")
  end

  def first_response_cycle?(history)
    return true if history.empty?
    return false unless history.length == 1

    first = history.first
    return false unless first.is_a?(Hash)

    first.fetch("classification", "").to_s == "initial" ||
      first.fetch("summary", "").to_s.match?(/initial challenge|missing-verdict trigger/i)
  end

  def review_mode_from_user_message(message)
    text = message.to_s
    return false if text.strip.empty?

    fix_intent_text = text.gsub(/no\s+fixes|без\s+фиксов|без\s+исправлени[йя]|не\s+фикси/i, "")
    text.match?(REVIEW_POSITIVE_RE) && !fix_intent_text.match?(FIX_INTENT_RE)
  end

  def verdict_match(text)
    normalized = normalize_verdict_input(text)
    match = normalized.match(SEVERITY_ZERO_PAIR_RE) || normalized.match(VERDICT_RE)
    return nil unless match

    match[0][0, 100]
  end

  def normalize_verdict_input(text)
    text.to_s.tr("\r\n", "  ").gsub(/[[:space:]]+/, " ").strip
  end

  def review_needs_more_findings?(current)
    text = current.to_s
    return true if text.match?(FIX_INTENT_RE)
    return true if verdict_match(text)

    !text.match?(/(?:file|path|severity|finding|findings|symbol|файл|путь|severity|серьезност|замечани)/i)
  end

  def repetitive?(current, history)
    prior = history.reverse.map { |entry| history_text(entry) }.find { |text| text.length >= 40 }
    return false unless prior

    current_tokens = token_set(current)
    prior_tokens = token_set(prior)
    return false if current_tokens.empty? || prior_tokens.empty?

    overlap = (current_tokens & prior_tokens).length.to_f
    smaller = [current_tokens.length, prior_tokens.length].min
    return false if smaller.zero?

    (overlap / smaller) >= 0.8
  end

  def history_text(entry)
    return "" unless entry.is_a?(Hash)

    %w[summary gaps rationale current_response].map { |key| entry[key].to_s }.join(" ").strip
  end

  def token_set(text)
    text.to_s.downcase.scan(/[[:alnum:]_а-яё]{4,}/i).uniq
  end

  def string_field(input, key)
    value = input[key]
    value.nil? ? "" : value.to_s
  end

  def array_field(input, key)
    value = input[key]
    value.is_a?(Array) ? value : []
  end

  def explicit_review_mode?(input)
    input.key?("review_mode")
  end

  def booleanish(value)
    value == true || value.to_s.downcase == "true" || value.to_s == "1"
  end

  def clean(rationale, confidence)
    {
      "classification" => "complete",
      "gaps_to_demand" => [],
      "rationale" => rationale,
      "confidence" => confidence
    }
  end

  def challenge(classification, gaps, rationale, confidence)
    {
      "classification" => classification,
      "gaps_to_demand" => gaps,
      "rationale" => rationale,
      "confidence" => confidence
    }
  end

  def unknown(reason_code, rationale)
    {
      "classification" => "unknown",
      "gaps_to_demand" => [],
      "rationale" => rationale,
      "confidence" => "0.000",
      "reason_code" => reason_code
    }
  end
end
