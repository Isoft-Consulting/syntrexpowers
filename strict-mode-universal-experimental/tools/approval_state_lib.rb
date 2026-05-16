#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "fdr_cycle_lib"
require_relative "global_ledger_lib"
require_relative "global_lock_lib"
require_relative "metadata_lib"
require_relative "normalized_event_lib"
require_relative "protected_baseline_lib"

class StrictModeApprovalState
  ZERO_HASH = "0" * 64
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze
  CONFIRM_LINE = /\Astrict-mode confirm ([0-9a-f]{64})\z/.freeze
  DEFAULT_CONFIRM_MAX_AGE_SEC = 600
  DEFAULT_CONFIRM_MIN_AGE_SEC = 0

  PENDING_DESTRUCTIVE_FIELDS = %w[
    schema_version
    kind
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    approval_hash
    created_at
    expires_at
    next_user_prompt_marker
    normalized_command
    command_hash
    command_hash_source
    block_reason_hash
    pending_record_hash
  ].freeze

  PROMPT_SEQUENCE_FIELDS = %w[
    schema_version
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    last_prompt_seq
    last_prompt_event_hash
    created_at
    updated_at
    sequence_hash
  ].freeze

  PROMPT_EVENT_FIELDS = %w[
    schema_version
    prompt_seq
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    turn_marker
    payload_hash
    ts
    previous_record_hash
    record_hash
  ].freeze

  AUDIT_COMMON_FIELDS = %w[
    schema_version
    log
    action
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    approval_hash
    pending_record_hash
    next_user_prompt_marker
    prompt_seq
    source
    ts
    previous_record_hash
    command_hash
    command_hash_source
    record_hash
  ].freeze

  AUDIT_CONSUMED_FIELDS = (AUDIT_COMMON_FIELDS + %w[
    marker_hash
    active_marker_path
    consumed_tombstone_path
    marker_pre_rename_fingerprint
    tombstone_fingerprint
  ]).freeze

  MARKER_FIELDS = %w[
    schema_version
    kind
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    approval_hash
    pending_record_hash
    next_user_prompt_marker
    approval_prompt_seq
    approval_log_record_hash
    source
    created_at
    expires_at
    marker_hash
  ].freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  def self.context(provider:, payload:, cwd:, project_dir:)
    identity = StrictModeFdrCycle.session_identity(provider, payload)
    return nil unless identity

    identity.merge(
      "provider" => provider,
      "cwd" => Pathname.new(cwd).expand_path.cleanpath.to_s,
      "project_dir" => Pathname.new(project_dir).expand_path.cleanpath.to_s
    )
  end

  def self.note_destructive_block!(state_root:, install_root:, provider:, payload:, payload_hash:, preflight:, cwd:, project_dir:, max_age_sec: DEFAULT_CONFIRM_MAX_AGE_SEC)
    return nil unless preflight.is_a?(Hash) &&
                      preflight.fetch("trusted", false) &&
                      preflight.fetch("decision", "") == "block" &&
                      preflight.fetch("reason_code", "") == "destructive-command"

    normalized = StrictModeNormalized.normalize(
      payload,
      provider: provider,
      logical_event: "pre-tool-use",
      cwd: cwd,
      project_dir: project_dir,
      payload_sha256: payload_hash
    )
    ctx = context(provider: provider, payload: payload, cwd: cwd, project_dir: project_dir)
    return nil unless ctx

    with_approval_locks!(install_root, state_root, ctx, "approval-block") do
      sequence = load_prompt_sequence(prompt_sequence_path(state_root, ctx), ctx)
      marker = next_prompt_marker(sequence.fetch("last_prompt_seq") + 1)
      pending = destructive_pending_record(ctx, normalized.fetch("tool"), preflight, marker, max_age_sec: max_age_sec)
      path = pending_path(state_root, ctx, pending.fetch("approval_hash"))
      existing = load_json_or_nil(path)
      if existing
        existing_errors = validate_pending_destructive(existing, ctx, path: path)
        unless existing_errors.empty?
          raise "#{path}: existing pending approval invalid: #{existing_errors.join("; ")}"
        end
        unless stale_pending?(existing, sequence.fetch("last_prompt_seq"))
          raise "pending approval ledger missing" unless pending_ledger_for_pending(state_root, ctx, existing)

          audit = blocked_audit_for_pending(state_root, existing) || append_destructive_audit!(
            state_root,
            ctx,
            action: "blocked",
            source: "pre-tool-hook",
            pending: existing,
            prompt_seq: 0
          )
          return approval_notice(existing, path, reused: true).merge("blocked_audit_record_hash" => audit.fetch("record_hash"))
        end
      end

      old_fingerprint = StrictModeGlobalLedger.fingerprint(path)
      atomic_write_json(path, pending)
      new_fingerprint = StrictModeGlobalLedger.fingerprint(path)
      StrictModeFdrCycle.append_session_ledger!(
        state_root,
        ctx,
        target_path: path,
        target_class: "pending-approval",
        operation: old_fingerprint.fetch("exists") == 1 ? "modify" : "create",
        old_fingerprint: old_fingerprint,
        new_fingerprint: new_fingerprint,
        related_record_hash: pending.fetch("pending_record_hash")
      )
      audit = append_destructive_audit!(
        state_root,
        ctx,
        action: "blocked",
        source: "pre-tool-hook",
        pending: pending,
        prompt_seq: 0
      )
      approval_notice(pending, path, reused: false).merge("blocked_audit_record_hash" => audit.fetch("record_hash"))
    end
  end

  def self.record_user_prompt!(state_root:, install_root:, provider:, payload:, payload_hash:, cwd:, project_dir:)
    normalized = StrictModeNormalized.normalize(
      payload,
      provider: provider,
      logical_event: "user-prompt-submit",
      cwd: cwd,
      project_dir: project_dir,
      payload_sha256: payload_hash
    )
    ctx = context(provider: provider, payload: payload, cwd: cwd, project_dir: project_dir)
    return { "prompt_seq" => 0, "marker_created" => false, "expired_swept" => [] } unless ctx

    with_approval_locks!(install_root, state_root, ctx, "prompt-event") do
      prompt_event = append_prompt_event!(state_root, ctx, payload_hash, normalized)
      approval_hash = exact_confirm_hash(normalized.fetch("prompt").fetch("text"))
      marker = approval_hash ? create_marker_for_prompt!(state_root, ctx, approval_hash, prompt_event.fetch("prompt_seq")) : nil
      # Чистим истёкшие confirmation markers и pending records одним
      # next-user-turn проходом. Sweep идёт ПОСЛЕ append_prompt_event,
      # чтобы prompt_seq был monotonic — невозможно создать и
      # истечь маркер в одном prompt'е (acceptance line 47).
      sweep_result = sweep_expired_approvals!(state_root, ctx, prompt_event.fetch("prompt_seq"))
      {
        "prompt_seq" => prompt_event.fetch("prompt_seq"),
        "prompt_event_hash" => prompt_event.fetch("record_hash"),
        "approval_hash" => approval_hash || "",
        "marker_created" => !marker.nil?,
        "marker_hash" => marker ? marker.fetch("marker_hash") : ZERO_HASH,
        "expired_swept" => sweep_result.fetch("swept"),
        "expired_sweep_errors" => sweep_result.fetch("errors")
      }
    end
  end

  # Идёт ПОД approval session+global lock'ом (вызывается из record_user_prompt!).
  # Возвращает hash:
  #   "swept"  — список approval_hash'ей успешно expired pending'ов
  #   "errors" — список { "path", "message", "error_class" } для тех,
  #              которые упали (corrupted JSON, rename failure, etc).
  # Раньше ошибки молча warn'ились в stderr и терялись. Теперь surface'им
  # через return value, чтобы caller (record_user_prompt!) включил
  # их в approval_summary; интегрируется с future log/ledger surface.
  # Каждый expired pending порождает:
  #   - audit с action="expired", source="user-prompt-hook"
  #   - rename pending -> expired-pending-... (idempotent)
  #   - если соответствующий confirm-marker ещё активен — rename
  #     в expired-confirm-...
  # Любая ошибка при отдельном pending'е не должна валить весь sweep —
  # записываем error и продолжаем (other pending'и тоже expire).
  def self.sweep_expired_approvals!(state_root, ctx, prompt_seq)
    result = { "swept" => [], "errors" => [] }
    return result unless prompt_seq.is_a?(Integer) && prompt_seq.positive?

    provider = ctx.fetch("provider")
    session_key = ctx.fetch("session_key")
    pattern = "pending-destructive-#{provider}-#{session_key}-*.json"
    Pathname.glob(Pathname.new(state_root).join(pattern)).each do |path|
      next unless path.file? && !path.symlink?

      begin
        record = load_json_or_nil(path)
        next unless record
        next unless expired?(record.fetch("expires_at"))

        expire_pending_record!(state_root, ctx, record, path, prompt_seq)
        result["swept"] << record.fetch("approval_hash")
      rescue RuntimeError, SystemCallError, ArgumentError, KeyError, JSON::ParserError => e
        message = e.message.to_s[0, 200]
        result["errors"] << {
          "path" => path.basename.to_s,
          "error_class" => e.class.name,
          "message" => message
        }
        warn "approval-sweep skip #{path}: #{e.class}: #{message}"
      end
    end
    result
  end

  # Возвращает уникальный путь tombstone'а для retry-сценария: тот же
  # approval_hash → тот же filename pending'a, но если предыдущий
  # tombstone уже занят (legitimate retry после expired), добавляем
  # UTC timestamp suffix чтобы не затереть предыдущее доказательство.
  # Для confirm-marker (no .json extension) helper тоже работает —
  # extname возвращает "" и мы получаем file.<ts>.tombstone-like name.
  def self.unique_tombstone_for_retry(source_path, prefix)
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
    extname = source_path.extname
    stem = source_path.basename(extname).to_s
    name = if extname.empty?
             "#{prefix}-#{stem}.#{timestamp}"
           else
             "#{prefix}-#{stem}.#{timestamp}#{extname}"
           end
    source_path.dirname.join(name)
  end

  # Pure-функция: принимает решение, надо ли expire'нуть pending.
  # Вынесено отдельно от expire_pending_record! чтобы можно было
  # unit-тестировать идемпотентность без full chain (locks, audit
  # log, ledger). Возвращает один из:
  #   :proceed — tombstone нет, pending есть → expire
  #   :skip_tombstone_only — tombstone уже есть, pending нет → idempotent skip
  #   :skip_ambiguous — есть и tombstone, и pending → manual review
  #   :skip_nothing — нет ни того, ни другого → race-removed
  def self.expire_pending_decision(pending_path, expired_pending_path)
    pending_exists = pending_path.file? && !pending_path.symlink?
    tombstone_exists = expired_pending_path.file? && !expired_pending_path.symlink?
    return :skip_ambiguous if pending_exists && tombstone_exists
    return :skip_tombstone_only if tombstone_exists
    return :skip_nothing unless pending_exists
    :proceed
  end

  def self.expire_pending_record!(state_root, ctx, pending, pending_path, prompt_seq)
    approval_hash = pending.fetch("approval_hash")
    marker_path = confirm_path(state_root, ctx, approval_hash)
    expired_pending_path = pending_path.dirname.join("expired-#{pending_path.basename}")
    decision = expire_pending_decision(pending_path, expired_pending_path)
    case decision
    when :skip_tombstone_only, :skip_nothing
      return nil
    when :skip_ambiguous
      # Legitimate retry: user снова блокирует ту же destructive
      # команду (same provider/session/cwd/approval_hash → same
      # pending filename) после того как предыдущий pending уже
      # expired в tombstone. Старый tombstone несёт original
      # expired-audit binding и нельзя его терять. Даём НОВОМУ
      # tombstone'у уникальный timestamp suffix; original tombstone
      # сохраняется, new pending получает свой expired audit
      # отдельно. Сохраняем observability для operator'а — retry-
      # collision должна быть видна в hook stderr даже когда sweep
      # продолжает работать.
      warn "approval-sweep retry-collision (same approval_hash re-block): preserving original tombstone, expiring new pending to timestamped path"
      expired_pending_path = unique_tombstone_for_retry(pending_path, "expired")
    end

    pending_pre_rename = StrictModeGlobalLedger.fingerprint(pending_path)
    marker_pre_rename = marker_path.exist? ? StrictModeGlobalLedger.fingerprint(marker_path) : nil

    # Rename FIRST: если rename падает (disk full, permission), audit
    # ещё не записан, и следующий sweep сможет re-try с того же
    # места. Если бы порядок был обратный, после rename failure
    # остался бы pending + audit "expired" — каждый последующий sweep
    # снова audited expiry, создавая дубли.
    File.rename(pending_path, expired_pending_path) if pending_path.file? && !pending_path.symlink?

    expired_marker_path = nil
    if marker_path.file? && !marker_path.symlink?
      base_expired_marker = marker_path.dirname.join("expired-#{marker_path.basename}")
      expired_marker_path = base_expired_marker.exist? ? unique_tombstone_for_retry(marker_path, "expired") : base_expired_marker
      File.rename(marker_path, expired_marker_path)
    end

    # После успешного rename(s) пишем audit и ledger entries. Если на
    # этом этапе случится failure, файлы уже в tombstone state, и
    # next sweep ранее проверит expired_pending_path.exist? и пропустит.
    audit = append_destructive_audit!(
      state_root,
      ctx,
      action: "expired",
      source: "user-prompt-hook",
      pending: pending,
      prompt_seq: prompt_seq
    )
    StrictModeFdrCycle.append_session_ledger!(
      state_root,
      ctx,
      target_path: expired_pending_path,
      target_class: "expired-pending",
      operation: "rename",
      old_fingerprint: pending_pre_rename,
      new_fingerprint: StrictModeGlobalLedger.fingerprint(expired_pending_path),
      related_record_hash: audit.fetch("record_hash")
    )
    if expired_marker_path
      StrictModeFdrCycle.append_session_ledger!(
        state_root,
        ctx,
        target_path: expired_marker_path,
        target_class: "expired-confirm-marker",
        operation: "rename",
        old_fingerprint: marker_pre_rename || StrictModeGlobalLedger.fingerprint(expired_marker_path),
        new_fingerprint: StrictModeGlobalLedger.fingerprint(expired_marker_path),
        related_record_hash: audit.fetch("record_hash")
      )
    end
    audit
  end

  def self.consume_destructive_confirmation!(state_root:, install_root:, provider:, payload:, payload_hash:, preflight:, cwd:, project_dir:, min_age_sec: nil)
    return { "consumed" => false } unless preflight.is_a?(Hash) &&
                                         preflight.fetch("trusted", false) &&
                                         preflight.fetch("decision", "") == "block" &&
                                         preflight.fetch("reason_code", "") == "destructive-command"

    normalized = StrictModeNormalized.normalize(
      payload,
      provider: provider,
      logical_event: "pre-tool-use",
      cwd: cwd,
      project_dir: project_dir,
      payload_sha256: payload_hash
    )
    ctx = context(provider: provider, payload: payload, cwd: cwd, project_dir: project_dir)
    return { "consumed" => false } unless ctx

    subject = destructive_subject(ctx, normalized.fetch("tool"), preflight)
    approval_hash = approval_hash_for(subject)
    marker_path = confirm_path(state_root, ctx, approval_hash)
    return { "consumed" => false, "approval_hash" => approval_hash } unless marker_path.file? && !marker_path.symlink?

    with_approval_locks!(install_root, state_root, ctx, "approval-consume") do
      pending = load_json_or_nil(pending_path(state_root, ctx, approval_hash))
      raise "pending approval missing for #{approval_hash}" unless pending

      pending_errors = validate_pending_destructive(pending, ctx, path: pending_path(state_root, ctx, approval_hash))
      raise "pending approval invalid: #{pending_errors.join("; ")}" unless pending_errors.empty?
      raise "pending approval ledger missing" unless pending_ledger_for_pending(state_root, ctx, pending)
      unless pending.fetch("command_hash") == subject.fetch("command_hash") &&
             pending.fetch("block_reason_hash") == subject.fetch("block_reason_hash")
        raise "pending approval does not match current destructive command"
      end

      marker = load_json(marker_path)
      marker_errors = validate_marker(marker, ctx, path: marker_path)
      raise "confirmation marker invalid: #{marker_errors.join("; ")}" unless marker_errors.empty?
      raise "confirmation marker pending hash mismatch" unless marker.fetch("pending_record_hash") == pending.fetch("pending_record_hash")
      raise "confirmation marker ledger missing" unless marker_ledger_for_marker(state_root, ctx, marker, marker_path)
      raise "confirmation marker expired" if expired?(marker.fetch("expires_at"))
      current_prompt_seq = load_prompt_sequence(prompt_sequence_path(state_root, ctx), ctx).fetch("last_prompt_seq")
      # Effective min-age читается ВНУТРИ approval lock'a (после
      # acquire global+session locks), чтобы закрыть race window
      # между read-config и use-config: операторский edit runtime.env
      # между чтением и проверкой больше не bypass'ает guard.
      # Если caller передал явный min_age_sec (например тест) —
      # используем его, иначе читаем из protected runtime config.
      effective_min_age_sec = min_age_sec.nil? ? read_protected_min_age_sec(install_root, state_root, project_dir) : min_age_sec
      if fails_min_age?(marker, current_prompt_seq, effective_min_age_sec)
        raise "confirmation marker fails min-age anti-forgery (created_at=#{marker.fetch("created_at")}, min_age_sec=#{effective_min_age_sec.to_i})"
      end
      confirmed = audit_record_by_hash(state_root, marker.fetch("approval_log_record_hash"))
      raise "confirmation audit missing" unless confirmed &&
                                            confirmed.fetch("action") == "confirmed" &&
                                            confirmed.fetch("source") == "user-prompt-hook" &&
                                            confirmed.fetch("approval_hash") == approval_hash &&
                                            confirmed.fetch("pending_record_hash") == pending.fetch("pending_record_hash")

      tombstone_path = consumed_confirm_path(state_root, ctx, approval_hash)
      raise "consumed confirmation tombstone already exists" if tombstone_path.exist?

      marker_pre_rename_fingerprint = StrictModeGlobalLedger.fingerprint(marker_path)
      old_tombstone_fingerprint = StrictModeGlobalLedger.fingerprint(tombstone_path)
      File.rename(marker_path, tombstone_path)
      tombstone_fingerprint = StrictModeGlobalLedger.fingerprint(tombstone_path)
      audit = append_destructive_audit!(
        state_root,
        ctx,
        action: "consumed",
        source: "pre-tool-hook",
        pending: pending,
        prompt_seq: 0,
        marker_hash: marker.fetch("marker_hash"),
        active_marker_path: marker_path,
        consumed_tombstone_path: tombstone_path,
        marker_pre_rename_fingerprint: marker_pre_rename_fingerprint,
        tombstone_fingerprint: tombstone_fingerprint
      )
      ledger = StrictModeFdrCycle.append_session_ledger!(
        state_root,
        ctx,
        target_path: tombstone_path,
        target_class: "consumed-tombstone",
        operation: "rename",
        old_fingerprint: old_tombstone_fingerprint,
        new_fingerprint: tombstone_fingerprint,
        related_record_hash: audit.fetch("record_hash")
      )
      raise "active confirmation marker still exists after consumption" if marker_path.exist?

      {
        "consumed" => true,
        "approval_hash" => approval_hash,
        "marker_hash" => marker.fetch("marker_hash"),
        "consumed_audit_record_hash" => audit.fetch("record_hash"),
        "consumed_ledger_record_hash" => ledger.fetch("record_hash"),
        "tombstone_path" => tombstone_path.to_s
      }
    end
  end

  # Читает STRICT_CONFIRM_MIN_AGE_SEC из trusted runtime config
  # внутри approval lock'а. Возвращает Integer (0 если ключ или
  # baseline недоступны), что эквивалентно "guard disabled" —
  # консистентно с DEFAULT_CONFIRM_MIN_AGE_SEC и с поведением
  # protected_runtime_settings в bin/strict-hook при untrusted baseline.
  def self.read_protected_min_age_sec(install_root, state_root, project_dir)
    loaded = StrictModeProtectedBaseline.load(
      install_root: install_root,
      state_root: state_root,
      project_dir: Pathname.new(project_dir),
      home: Dir.home
    )
    return DEFAULT_CONFIRM_MIN_AGE_SEC unless loaded.fetch("trusted")

    runtime = loaded.fetch("config_results").fetch("runtime.env", { "records" => [] })
    record = runtime.fetch("records").find { |r| r.fetch("key") == "STRICT_CONFIRM_MIN_AGE_SEC" }
    return DEFAULT_CONFIRM_MIN_AGE_SEC unless record

    Integer(record.fetch("value"))
  rescue ArgumentError, KeyError, SystemCallError, RuntimeError
    DEFAULT_CONFIRM_MIN_AGE_SEC
  end

  def self.with_approval_locks!(install_root, state_root, context, transaction_kind)
    global_lock = StrictModeGlobalLock.acquire!(install_root, state_root: state_root, transaction_kind: transaction_kind)
    begin
      StrictModeFdrCycle.with_session_lock!(state_root, context, transaction_kind) { yield }
    ensure
      global_lock.release if global_lock
    end
  end

  def self.append_prompt_event!(state_root, context, payload_hash, normalized_event)
    sequence_pathname = prompt_sequence_path(state_root, context)
    event_path = prompt_events_path(state_root, context)
    sequence = load_prompt_sequence(sequence_pathname, context)
    old_event_fingerprint = StrictModeGlobalLedger.fingerprint(event_path)
    previous_record_hash = sequence.fetch("last_prompt_event_hash")
    prompt_seq = sequence.fetch("last_prompt_seq") + 1
    record = {
      "schema_version" => 1,
      "prompt_seq" => prompt_seq,
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "turn_marker" => prompt_turn_marker(context, prompt_seq, payload_hash),
      "payload_hash" => payload_hash,
      "ts" => Time.now.utc.iso8601,
      "previous_record_hash" => previous_record_hash,
      "record_hash" => ""
    }
    record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
    errors = validate_prompt_event(record, context, expected_previous_hash: previous_record_hash)
    raise "prompt event invalid: #{errors.join("; ")}" unless errors.empty?

    append_jsonl(event_path, record)
    new_event_fingerprint = StrictModeGlobalLedger.fingerprint(event_path)
    StrictModeFdrCycle.append_session_ledger!(
      state_root,
      context,
      target_path: event_path,
      target_class: "prompt-event-log",
      operation: "append",
      old_fingerprint: old_event_fingerprint,
      new_fingerprint: new_event_fingerprint,
      related_record_hash: record.fetch("record_hash")
    )

    old_sequence_fingerprint = StrictModeGlobalLedger.fingerprint(sequence_pathname)
    updated = sequence.merge(
      "last_prompt_seq" => prompt_seq,
      "last_prompt_event_hash" => record.fetch("record_hash"),
      "updated_at" => record.fetch("ts"),
      "sequence_hash" => ""
    )
    updated["sequence_hash"] = StrictModeMetadata.hash_record(updated, "sequence_hash")
    sequence_errors = validate_prompt_sequence(updated, context)
    raise "prompt sequence invalid: #{sequence_errors.join("; ")}" unless sequence_errors.empty?
    atomic_write_json(sequence_pathname, updated)
    new_sequence_fingerprint = StrictModeGlobalLedger.fingerprint(sequence_pathname)
    StrictModeFdrCycle.append_session_ledger!(
      state_root,
      context,
      target_path: sequence_pathname,
      target_class: "prompt-sequence",
      operation: old_sequence_fingerprint.fetch("exists") == 1 ? "modify" : "create",
      old_fingerprint: old_sequence_fingerprint,
      new_fingerprint: new_sequence_fingerprint,
      related_record_hash: record.fetch("record_hash")
    )
    record
  end

  def self.create_marker_for_prompt!(state_root, context, approval_hash, prompt_seq)
    pending_pathname = pending_path(state_root, context, approval_hash)
    return nil unless pending_pathname.file? && !pending_pathname.symlink?

    pending = load_json(pending_pathname)
    pending_errors = validate_pending_destructive(pending, context, path: pending_pathname)
    raise "pending approval invalid: #{pending_errors.join("; ")}" unless pending_errors.empty?
    return nil unless pending.fetch("next_user_prompt_marker") == next_prompt_marker(prompt_seq)
    return nil if expired?(pending.fetch("expires_at"))
    raise "pending approval ledger missing" unless pending_ledger_for_pending(state_root, context, pending)
    return nil unless blocked_audit_for_pending(state_root, pending)

    audit = append_destructive_audit!(
      state_root,
      context,
      action: "confirmed",
      source: "user-prompt-hook",
      pending: pending,
      prompt_seq: prompt_seq
    )
    marker = {
      "schema_version" => 1,
      "kind" => "destructive-confirm",
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "approval_hash" => pending.fetch("approval_hash"),
      "pending_record_hash" => pending.fetch("pending_record_hash"),
      "next_user_prompt_marker" => pending.fetch("next_user_prompt_marker"),
      "approval_prompt_seq" => prompt_seq,
      "approval_log_record_hash" => audit.fetch("record_hash"),
      "source" => "user-prompt-hook",
      "created_at" => Time.now.utc.iso8601,
      "expires_at" => pending.fetch("expires_at"),
      "marker_hash" => ""
    }
    marker["marker_hash"] = StrictModeMetadata.hash_record(marker, "marker_hash")
    marker_errors = validate_marker(marker, context, path: confirm_path(state_root, context, approval_hash))
    raise "confirmation marker invalid: #{marker_errors.join("; ")}" unless marker_errors.empty?

    path = confirm_path(state_root, context, approval_hash)
    old_fingerprint = StrictModeGlobalLedger.fingerprint(path)
    atomic_write_json(path, marker)
    new_fingerprint = StrictModeGlobalLedger.fingerprint(path)
    begin
      StrictModeFdrCycle.append_session_ledger!(
        state_root,
        context,
        target_path: path,
        target_class: "approval-marker",
        operation: "create",
        old_fingerprint: old_fingerprint,
        new_fingerprint: new_fingerprint,
        related_record_hash: marker.fetch("marker_hash")
      )
    rescue RuntimeError, SystemCallError
      FileUtils.rm_f(path) if path.file? && !path.symlink?
      raise
    end
    marker
  end

  def self.destructive_pending_record(context, tool, preflight, next_marker, max_age_sec:)
    now = Time.now.utc
    subject = destructive_subject(context, tool, preflight)
    approval_hash = approval_hash_for(subject)
    record = {
      "schema_version" => 1,
      "kind" => "destructive-confirm",
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "approval_hash" => approval_hash,
      "created_at" => now.iso8601,
      "expires_at" => (now + max_age_sec).iso8601,
      "next_user_prompt_marker" => next_marker,
      "normalized_command" => normalized_shell_command(tool),
      "command_hash" => subject.fetch("command_hash"),
      "command_hash_source" => "shell-string",
      "block_reason_hash" => subject.fetch("block_reason_hash"),
      "pending_record_hash" => ""
    }
    record["pending_record_hash"] = StrictModeMetadata.hash_record(record, "pending_record_hash")
    errors = validate_pending_destructive(record, context)
    raise "pending approval invalid: #{errors.join("; ")}" unless errors.empty?
    record
  end

  def self.destructive_subject(context, tool, preflight)
    command = normalized_shell_command(tool)
    command_hash = Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "normalized_command" => command,
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "command_hash_source" => "shell-string"
    }))
    block_reason_hash = Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "gate" => "destructive-shell",
      "block_class" => "destructive-command",
      "reason_code" => preflight.fetch("reason_code"),
      "reason_hash" => preflight.fetch("reason_hash"),
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir")
    }))
    {
      "kind" => "destructive-confirm",
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "command_hash" => command_hash,
      "command_hash_source" => "shell-string",
      "block_reason_hash" => block_reason_hash
    }
  end

  def self.approval_hash_for(subject)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json(subject))
  end

  def self.append_destructive_audit!(state_root, context, action:, source:, pending:, prompt_seq:, marker_hash: nil, active_marker_path: nil, consumed_tombstone_path: nil, marker_pre_rename_fingerprint: nil, tombstone_fingerprint: nil)
    path = destructive_log_path(state_root)
    old_fingerprint = StrictModeGlobalLedger.fingerprint(path)
    previous_record_hash = last_audit_record_hash(path)
    record = {
      "schema_version" => 1,
      "log" => "destructive",
      "action" => action,
      "provider" => context.fetch("provider"),
      "session_key" => context.fetch("session_key"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "approval_hash" => pending.fetch("approval_hash"),
      "pending_record_hash" => pending.fetch("pending_record_hash"),
      "next_user_prompt_marker" => pending.fetch("next_user_prompt_marker"),
      "prompt_seq" => prompt_seq,
      "source" => source,
      "ts" => Time.now.utc.iso8601,
      "previous_record_hash" => previous_record_hash,
      "command_hash" => pending.fetch("command_hash"),
      "command_hash_source" => "shell-string",
      "record_hash" => ""
    }
    if action == "consumed"
      record = record.merge(
        "marker_hash" => marker_hash,
        "active_marker_path" => Pathname.new(active_marker_path).to_s,
        "consumed_tombstone_path" => Pathname.new(consumed_tombstone_path).to_s,
        "marker_pre_rename_fingerprint" => marker_pre_rename_fingerprint,
        "tombstone_fingerprint" => tombstone_fingerprint
      )
    end
    record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
    errors = validate_destructive_audit(record, context, expected_previous_hash: previous_record_hash)
    raise "destructive audit invalid: #{errors.join("; ")}" unless errors.empty?

    old_size = path.file? && !path.symlink? ? path.size : 0
    new_file = !path.exist?
    append_jsonl(path, record)
    new_fingerprint = StrictModeGlobalLedger.fingerprint(path)
    begin
      ledger = StrictModeGlobalLedger.append_global!(
        state_root,
        writer: "strict-hook",
        target_path: path,
        target_class: "approval-audit-log",
        operation: "append",
        old_fingerprint: old_fingerprint,
        new_fingerprint: new_fingerprint,
        related_record_hash: record.fetch("record_hash"),
        context: context
      )
    rescue RuntimeError, SystemCallError
      rollback_jsonl_append(path, old_size, new_file)
      raise
    end
    record.merge("ledger_record_hash" => ledger.fetch("record_hash"))
  end

  def self.approval_notice(pending, path, reused:)
    {
      "approval_hash" => pending.fetch("approval_hash"),
      "pending_record_hash" => pending.fetch("pending_record_hash"),
      "pending_path" => path.to_s,
      "next_user_prompt_marker" => pending.fetch("next_user_prompt_marker"),
      "phrase" => "strict-mode confirm #{pending.fetch("approval_hash")}",
      "reused" => reused
    }
  end

  def self.exact_confirm_hash(prompt_text)
    prompt_text.to_s.each_line do |line|
      match = CONFIRM_LINE.match(line.strip)
      return match[1] if match
    end
    nil
  end

  def self.normalized_shell_command(tool)
    tool.fetch("command").to_s.rstrip
  end

  def self.next_prompt_marker(prompt_seq)
    "prompt-seq:#{prompt_seq}"
  end

  def self.prompt_turn_marker(context, prompt_seq, payload_hash)
    Digest::SHA256.hexdigest(StrictModeMetadata.canonical_json({
      "provider" => context.fetch("provider"),
      "raw_session_hash" => context.fetch("raw_session_hash"),
      "cwd" => context.fetch("cwd"),
      "project_dir" => context.fetch("project_dir"),
      "prompt_seq" => prompt_seq,
      "payload_hash" => payload_hash
    }))
  end

  def self.pending_path(state_root, context, approval_hash)
    Pathname.new(state_root).join("pending-destructive-#{context.fetch("provider")}-#{context.fetch("session_key")}-#{approval_hash}.json")
  end

  def self.confirm_path(state_root, context, approval_hash)
    Pathname.new(state_root).join("confirm-#{context.fetch("provider")}-#{context.fetch("session_key")}-#{approval_hash}")
  end

  def self.consumed_confirm_path(state_root, context, approval_hash)
    Pathname.new(state_root).join("consumed-confirm-#{context.fetch("provider")}-#{context.fetch("session_key")}-#{approval_hash}.json")
  end

  def self.destructive_log_path(state_root)
    Pathname.new(state_root).join("destructive-log.jsonl")
  end

  def self.prompt_sequence_path(state_root, context)
    Pathname.new(state_root).join("prompt-seq-#{context.fetch("provider")}-#{context.fetch("session_key")}.json")
  end

  def self.prompt_events_path(state_root, context)
    Pathname.new(state_root).join("prompt-events-#{context.fetch("provider")}-#{context.fetch("session_key")}.jsonl")
  end

  def self.load_prompt_sequence(path, context)
    if !Pathname.new(path).exist?
      now = Time.now.utc.iso8601
      record = {
        "schema_version" => 1,
        "provider" => context.fetch("provider"),
        "session_key" => context.fetch("session_key"),
        "raw_session_hash" => context.fetch("raw_session_hash"),
        "cwd" => context.fetch("cwd"),
        "project_dir" => context.fetch("project_dir"),
        "last_prompt_seq" => 0,
        "last_prompt_event_hash" => ZERO_HASH,
        "created_at" => now,
        "updated_at" => now,
        "sequence_hash" => ""
      }
      record["sequence_hash"] = StrictModeMetadata.hash_record(record, "sequence_hash")
      return record
    end

    record = load_json(path)
    errors = validate_prompt_sequence(record, context)
    raise "#{path}: prompt sequence invalid: #{errors.join("; ")}" unless errors.empty?
    record
  end

  def self.last_audit_record_hash(path)
    records = load_audit_records(path)
    records.empty? ? ZERO_HASH : records.last.fetch("record_hash")
  end

  def self.audit_record_by_hash(state_root, record_hash)
    return nil unless sha256?(record_hash)

    load_audit_records(destructive_log_path(state_root)).find { |record| record.fetch("record_hash") == record_hash }
  end

  def self.blocked_audit_for_pending(state_root, pending)
    load_audit_records(destructive_log_path(state_root)).reverse.find do |record|
      record.fetch("action") == "blocked" &&
        record.fetch("source") == "pre-tool-hook" &&
        record.fetch("approval_hash") == pending.fetch("approval_hash") &&
        record.fetch("pending_record_hash") == pending.fetch("pending_record_hash") &&
        record.fetch("next_user_prompt_marker") == pending.fetch("next_user_prompt_marker") &&
        record.fetch("command_hash") == pending.fetch("command_hash") &&
        record.fetch("command_hash_source") == pending.fetch("command_hash_source")
    end
  end

  def self.pending_ledger_for_pending(state_root, context, pending)
    ledger_record_for(
      state_root,
      context,
      target_path: pending_path(state_root, context, pending.fetch("approval_hash")),
      target_class: "pending-approval",
      operations: %w[create modify],
      related_record_hash: pending.fetch("pending_record_hash")
    )
  end

  def self.marker_ledger_for_marker(state_root, context, marker, marker_path)
    ledger_record_for(
      state_root,
      context,
      target_path: marker_path,
      target_class: "approval-marker",
      operations: %w[create],
      related_record_hash: marker.fetch("marker_hash")
    )
  end

  def self.ledger_record_for(state_root, context, target_path:, target_class:, operations:, related_record_hash:)
    path = StrictModeFdrCycle.ledger_path(state_root, context.fetch("provider"), context.fetch("session_key"))
    StrictModeFdrCycle.load_session_ledger_records(path).reverse.find do |record|
      record.fetch("writer") == "strict-hook" &&
        record.fetch("provider") == context.fetch("provider") &&
        record.fetch("session_key") == context.fetch("session_key") &&
        record.fetch("raw_session_hash") == context.fetch("raw_session_hash") &&
        record.fetch("cwd") == context.fetch("cwd") &&
        record.fetch("project_dir") == context.fetch("project_dir") &&
        record.fetch("target_path") == Pathname.new(target_path).to_s &&
        record.fetch("target_class") == target_class &&
        operations.include?(record.fetch("operation")) &&
        record.fetch("related_record_hash") == related_record_hash
    end
  end

  def self.load_audit_records(path)
    path = Pathname.new(path)
    return [] unless path.exist?
    raise "#{path}: audit log must be a file" unless path.file?
    raise "#{path}: audit log must not be a symlink" if path.symlink?

    previous = ZERO_HASH
    path.read.lines.each_with_index.map do |line, index|
      text = line.strip
      raise "#{path}: blank audit line #{index + 1}" if text.empty?

      record = JSON.parse(text, object_class: DuplicateKeyHash)
      record = JSON.parse(JSON.generate(record))
      errors = validate_destructive_audit(record, nil, expected_previous_hash: previous)
      raise "#{path}: invalid audit line #{index + 1}: #{errors.join("; ")}" unless errors.empty?

      previous = record.fetch("record_hash")
      record
    end
  end

  def self.load_json(path)
    path = Pathname.new(path)
    raise "#{path}: JSON state must be a file" unless path.file?
    raise "#{path}: JSON state must not be a symlink" if path.symlink?

    record = JSON.parse(path.read, object_class: DuplicateKeyHash)
    raise "#{path}: JSON root must be an object" unless record.is_a?(Hash)

    JSON.parse(JSON.generate(record))
  end

  def self.load_json_or_nil(path)
    return nil unless Pathname.new(path).exist?

    load_json(path)
  end

  def self.atomic_write_json(path, record)
    path = Pathname.new(path)
    path.dirname.mkpath
    File.chmod(0o700, path.dirname) if path.dirname.directory?
    tmp = path.dirname.join(".#{path.basename}.tmp-#{$$}-#{SecureRandom.hex(4)}")
    tmp.write(JSON.pretty_generate(record) + "\n")
    File.chmod(0o600, tmp)
    File.rename(tmp, path)
  end

  def self.append_jsonl(path, record)
    path = Pathname.new(path)
    path.dirname.mkpath
    File.chmod(0o700, path.dirname) if path.dirname.directory?
    new_file = !path.exist?
    File.open(path.to_s, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.write(JSON.generate(record) + "\n") }
    File.chmod(0o600, path) if new_file
  end

  def self.rollback_jsonl_append(path, old_size, new_file)
    path = Pathname.new(path)
    if new_file
      FileUtils.rm_f(path) if path.file? && !path.symlink?
    elsif path.file? && !path.symlink?
      File.open(path.to_s, "r+b") { |file| file.truncate(old_size) }
    end
  rescue SystemCallError
    nil
  end

  def self.validate_pending_destructive(record, context = nil, path: nil)
    return ["pending record must be an object"] unless record.is_a?(Hash)

    errors = []
    exact_fields(errors, record, PENDING_DESTRUCTIVE_FIELDS, "pending")
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "kind must be destructive-confirm" unless record.fetch("kind") == "destructive-confirm"
    %w[provider session_key raw_session_hash cwd project_dir approval_hash created_at expires_at next_user_prompt_marker normalized_command command_hash_source block_reason_hash pending_record_hash].each do |field|
      errors << "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty?
    end
    %w[approval_hash command_hash block_reason_hash pending_record_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "command_hash_source must be shell-string" unless record.fetch("command_hash_source") == "shell-string"
    errors << "next_user_prompt_marker malformed" unless prompt_marker_seq(record.fetch("next_user_prompt_marker"))
    errors << "pending_record_hash mismatch" if sha256?(record.fetch("pending_record_hash")) &&
      StrictModeMetadata.hash_record(record, "pending_record_hash") != record.fetch("pending_record_hash")
    if context
      %w[provider session_key raw_session_hash cwd project_dir].each do |field|
        errors << "#{field} tuple mismatch" unless record.fetch(field) == context.fetch(field)
      end
    end
    if path
      expected_suffix = "#{record.fetch("approval_hash")}.json"
      errors << "filename approval_hash binding mismatch" unless Pathname.new(path).basename.to_s.end_with?(expected_suffix)
    end
    parse_time(record.fetch("created_at"), "created_at", errors)
    parse_time(record.fetch("expires_at"), "expires_at", errors)
    errors
  end

  def self.validate_marker(record, context = nil, path: nil)
    return ["marker must be an object"] unless record.is_a?(Hash)

    errors = []
    exact_fields(errors, record, MARKER_FIELDS, "marker")
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "kind must be destructive-confirm" unless record.fetch("kind") == "destructive-confirm"
    errors << "source must be user-prompt-hook" unless record.fetch("source") == "user-prompt-hook"
    %w[provider session_key raw_session_hash cwd project_dir approval_hash pending_record_hash next_user_prompt_marker approval_log_record_hash created_at expires_at marker_hash].each do |field|
      errors << "#{field} must be a non-empty string" unless field == "approval_prompt_seq" || (record.fetch(field).is_a?(String) && !record.fetch(field).empty?)
    end
    %w[approval_hash pending_record_hash approval_log_record_hash marker_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "approval_prompt_seq must be positive integer" unless record.fetch("approval_prompt_seq").is_a?(Integer) && record.fetch("approval_prompt_seq").positive?
    errors << "next_user_prompt_marker mismatch" unless record.fetch("next_user_prompt_marker") == next_prompt_marker(record.fetch("approval_prompt_seq"))
    errors << "marker_hash mismatch" if sha256?(record.fetch("marker_hash")) &&
      StrictModeMetadata.hash_record(record, "marker_hash") != record.fetch("marker_hash")
    if context
      %w[provider session_key raw_session_hash cwd project_dir].each do |field|
        errors << "#{field} tuple mismatch" unless record.fetch(field) == context.fetch(field)
      end
    end
    if path
      errors << "filename approval_hash binding mismatch" unless Pathname.new(path).basename.to_s.include?(record.fetch("approval_hash"))
    end
    parse_time(record.fetch("created_at"), "created_at", errors)
    parse_time(record.fetch("expires_at"), "expires_at", errors)
    errors
  end

  def self.validate_destructive_audit(record, context = nil, expected_previous_hash: nil)
    return ["audit record must be an object"] unless record.is_a?(Hash)

    errors = []
    expected_fields = record["action"] == "consumed" ? AUDIT_CONSUMED_FIELDS : AUDIT_COMMON_FIELDS
    exact_fields(errors, record, expected_fields, "destructive audit")
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "log must be destructive" unless record.fetch("log") == "destructive"
    source_for_action = {
      "blocked" => "pre-tool-hook",
      "confirmed" => "user-prompt-hook",
      "consumed" => "pre-tool-hook",
      "expired" => "user-prompt-hook"
    }
    errors << "action invalid" unless source_for_action.key?(record.fetch("action"))
    errors << "source invalid for action" if source_for_action.key?(record.fetch("action")) && record.fetch("source") != source_for_action.fetch(record.fetch("action"))
    errors << "prompt_seq must be non-negative integer" unless record.fetch("prompt_seq").is_a?(Integer) && record.fetch("prompt_seq") >= 0
    errors << "prompt_seq must be nonzero for user-prompt-hook" if record.fetch("source") == "user-prompt-hook" && record.fetch("prompt_seq") <= 0
    errors << "prompt_seq must be zero outside user-prompt-hook" if record.fetch("source") != "user-prompt-hook" && record.fetch("prompt_seq") != 0
    %w[provider session_key raw_session_hash cwd project_dir approval_hash pending_record_hash next_user_prompt_marker command_hash command_hash_source previous_record_hash record_hash].each do |field|
      errors << "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty?
    end
    %w[approval_hash pending_record_hash command_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "command_hash_source must be shell-string" unless record.fetch("command_hash_source") == "shell-string"
    errors << "previous_record_hash mismatch" if expected_previous_hash && record.fetch("previous_record_hash") != expected_previous_hash
    errors << "record_hash mismatch" if sha256?(record.fetch("record_hash")) &&
      StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
    if context
      %w[provider session_key raw_session_hash cwd project_dir].each do |field|
        errors << "#{field} tuple mismatch" unless record.fetch(field) == context.fetch(field)
      end
    end
    if record.fetch("action") == "consumed"
      %w[marker_hash].each { |field| errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field)) }
      %w[active_marker_path consumed_tombstone_path].each { |field| errors << "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty? }
      %w[marker_pre_rename_fingerprint tombstone_fingerprint].each do |field|
        errors.concat(StrictModeGlobalLedger.validate_fingerprint(record.fetch(field)).map { |error| "#{field}: #{error}" })
      end
    end
    parse_time(record.fetch("ts"), "ts", errors)
    errors
  end

  def self.validate_prompt_sequence(record, context)
    return ["prompt sequence must be an object"] unless record.is_a?(Hash)

    errors = []
    exact_fields(errors, record, PROMPT_SEQUENCE_FIELDS, "prompt sequence")
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    %w[provider session_key raw_session_hash cwd project_dir created_at updated_at sequence_hash].each do |field|
      errors << "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty?
    end
    %w[provider session_key raw_session_hash cwd project_dir].each do |field|
      errors << "#{field} tuple mismatch" unless record.fetch(field) == context.fetch(field)
    end
    errors << "last_prompt_seq must be non-negative integer" unless record.fetch("last_prompt_seq").is_a?(Integer) && record.fetch("last_prompt_seq") >= 0
    errors << "last_prompt_event_hash must be lowercase SHA-256" unless sha256?(record.fetch("last_prompt_event_hash"))
    errors << "sequence_hash must be lowercase SHA-256" unless sha256?(record.fetch("sequence_hash"))
    errors << "zero prompt-event sentinel mismatch" if record.fetch("last_prompt_seq") == 0 && record.fetch("last_prompt_event_hash") != ZERO_HASH
    errors << "sequence_hash mismatch" if sha256?(record.fetch("sequence_hash")) &&
      StrictModeMetadata.hash_record(record, "sequence_hash") != record.fetch("sequence_hash")
    parse_time(record.fetch("created_at"), "created_at", errors)
    parse_time(record.fetch("updated_at"), "updated_at", errors)
    errors
  end

  def self.validate_prompt_event(record, context, expected_previous_hash: nil)
    return ["prompt event must be an object"] unless record.is_a?(Hash)

    errors = []
    exact_fields(errors, record, PROMPT_EVENT_FIELDS, "prompt event")
    return errors unless errors.empty?

    errors << "schema_version must be 1" unless record.fetch("schema_version") == 1
    errors << "prompt_seq must be positive integer" unless record.fetch("prompt_seq").is_a?(Integer) && record.fetch("prompt_seq").positive?
    %w[provider session_key raw_session_hash cwd project_dir turn_marker payload_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be a non-empty string" unless record.fetch(field).is_a?(String) && !record.fetch(field).empty?
    end
    %w[provider session_key raw_session_hash cwd project_dir].each do |field|
      errors << "#{field} tuple mismatch" unless record.fetch(field) == context.fetch(field)
    end
    %w[raw_session_hash turn_marker payload_hash previous_record_hash record_hash].each do |field|
      errors << "#{field} must be lowercase SHA-256" unless sha256?(record.fetch(field))
    end
    errors << "previous_record_hash mismatch" if expected_previous_hash && record.fetch("previous_record_hash") != expected_previous_hash
    errors << "record_hash mismatch" if sha256?(record.fetch("record_hash")) &&
      StrictModeMetadata.hash_record(record, "record_hash") != record.fetch("record_hash")
    parse_time(record.fetch("ts"), "ts", errors)
    errors
  end

  def self.stale_pending?(pending, last_prompt_seq)
    marker_seq = prompt_marker_seq(pending.fetch("next_user_prompt_marker"))
    marker_seq && marker_seq <= last_prompt_seq
  end

  def self.expired?(iso8601)
    Time.iso8601(iso8601) <= Time.now.utc
  rescue ArgumentError
    true
  end

  # Cap на размер approval_evidence в одном turn-baseline: защита
  # от unbounded grow'a baseline JSON при тысячах consume audits
  # между turns (adversarial или buggy session). При превышении —
  # берём только последние N записей (по времени), это сохраняет
  # самое свежее доказательство consumption'а.
  TURN_BASELINE_APPROVAL_EVIDENCE_CAP = 512
  # Минимально допустимый cap. Запретить cap = 0 / negative /
  # non-Integer — иначе вызывающий мог бы скрытно отключить
  # bound'енье через runtime config drift или typo. Если кэп
  # выглядит инвалидно — fallback к умолчанию + warn.
  TURN_BASELINE_APPROVAL_EVIDENCE_CAP_MIN = 1

  # Sentinel-shape для truncation header: должен содержать те же
  # ключи, что и обычный evidence record, чтобы consumer'ы, делающие
  # `entry.fetch("approval_hash")`, не получали KeyError. Реальные
  # содержимые поля (approval_hash и др.) — ZERO sentinel'ы, чтобы
  # их нельзя было перепутать с реальным consumption proof'ом.
  EVIDENCE_TRUNCATION_HEADER_KIND = "approval-evidence-truncated"

  # Возвращает evidence-entries по destructive-confirmation
  # consume'ам за период (since, until]. Используется
  # turn-baseline builder'ом, чтобы зафиксировать previous-turn
  # consumption proof (acceptance line 53). Каждая запись несёт
  # approval_hash, audit record_hash и pre-rename fingerprint —
  # этого достаточно, чтобы Stop/judge мог per-turn проверить, что
  # consume действительно прошёл через trusted chain.
  #
  # Аргументы:
  #   cap — макс. число reality entries; при overflow возвращаются
  #         последние cap записей плюс header с kind ==
  #         EVIDENCE_TRUNCATION_HEADER_KIND. Невалидный cap (0,
  #         negative, non-Integer) откатывается к
  #         TURN_BASELINE_APPROVAL_EVIDENCE_CAP с warning.
  #
  # При повреждении destructive-log (RuntimeError из blank-line
  # detector, JSON::ParserError, etc) метод возвращает sentinel
  # с kind == "approval-evidence-read-failed" и непустым reason —
  # baseline builder увидит non-empty array и сможет различить
  # реальный empty turn от corrupted-log scenario.
  def self.consumed_audit_evidence_since(state_root, ctx, since_iso8601, until_iso8601 = nil, cap: TURN_BASELINE_APPROVAL_EVIDENCE_CAP)
    effective_cap = if cap.is_a?(Integer) && cap >= TURN_BASELINE_APPROVAL_EVIDENCE_CAP_MIN
                      cap
                    else
                      warn "consumed_audit_evidence_since: invalid cap #{cap.inspect}, falling back to default #{TURN_BASELINE_APPROVAL_EVIDENCE_CAP}"
                      TURN_BASELINE_APPROVAL_EVIDENCE_CAP
                    end
    threshold_since = Time.iso8601(since_iso8601.to_s)
    threshold_until = until_iso8601.nil? ? nil : Time.iso8601(until_iso8601.to_s)
    records = load_audit_records(destructive_log_path(state_root))
    matched = records.select do |record|
      next false unless record.fetch("action") == "consumed"
      next false unless evidence_tuple_matches?(record, ctx)

      ts = Time.iso8601(record.fetch("ts"))
      next false unless ts > threshold_since
      next false if threshold_until && ts > threshold_until

      true
    end
    truncated_count = 0
    dropped_chain_anchor = ZERO_HASH
    if matched.length > effective_cap
      truncated_count = matched.length - effective_cap
      # Chain binding: previous_record_hash старейшей выжившей записи
      # фиксирует, где именно в hash-chain была обрезка. Без этого
      # `truncated_count` cryptographically не bound — атакующий мог
      # бы inject'ить фейковое значение в baseline. Связав header
      # с reachable chain anchor, judge может re-walk audit log и
      # подтвердить, что между ZERO_HASH (или предыдущим baseline'ом)
      # и этим anchor'ом действительно жили truncated_count записей.
      dropped_chain_anchor = matched[matched.length - effective_cap].fetch("previous_record_hash")
      matched = matched.last(effective_cap)
    end
    entries = matched.map do |record|
      {
        "kind" => "approval-evidence-consumed",
        "approval_hash" => record.fetch("approval_hash"),
        "audit_hash" => record.fetch("record_hash"),
        "marker_hash" => record.fetch("marker_hash"),
        "marker_pre_rename_fingerprint" => record.fetch("marker_pre_rename_fingerprint"),
        "tombstone_fingerprint" => record.fetch("tombstone_fingerprint"),
        "consumed_at" => record.fetch("ts")
      }
    end
    if truncated_count.positive?
      entries.unshift(evidence_sentinel(
        EVIDENCE_TRUNCATION_HEADER_KIND,
        "approval-evidence-cap-#{effective_cap}",
        truncated_count,
        previous_audit_hash: dropped_chain_anchor
      ))
    end
    entries
  rescue RuntimeError, ArgumentError, KeyError, SystemCallError, JSON::ParserError => e
    # destructive-log читается без global lock (writer держит global
    # lock, sweep/baseline под session lock). В redкой race window
    # load_audit_records может увидеть partial-write line или
    # неполный JSON. ОДНАКО же ошибка может означать и реальную
    # corruption диска — не "пустой turn". Возвращаем sentinel
    # с kind == "approval-evidence-read-failed", чтобы Stop gate /
    # judge различали empty-turn от read-failure и могли поднять
    # тревогу. error.class и message не помещаем в baseline (PII,
    # бесконтрольный размер), а указываем reason'ом.
    [evidence_sentinel(
      "approval-evidence-read-failed",
      "audit-log-read-error: #{e.class}",
      0
    )]
  end

  def self.evidence_sentinel(kind, reason, truncated_count, previous_audit_hash: ZERO_HASH)
    {
      "kind" => kind,
      "approval_hash" => ZERO_HASH,
      "audit_hash" => ZERO_HASH,
      "marker_hash" => ZERO_HASH,
      "marker_pre_rename_fingerprint" => zero_fingerprint,
      "tombstone_fingerprint" => zero_fingerprint,
      "consumed_at" => "1970-01-01T00:00:00Z",
      "truncated_count" => truncated_count,
      "truncation_reason" => reason,
      "previous_audit_hash" => previous_audit_hash
    }
  end

  # Каноническая "missing" fingerprint shape берётся напрямую из
  # StrictModeGlobalLedger.missing_fingerprint — нет смысла дублировать
  # структуру здесь, иначе при future drift в global_ledger_lib
  # audit-валидатор начнёт отвергать sentinel'ы. missing_fingerprint
  # возвращает shape без обращения к файловой системе (не как
  # `fingerprint(path)` который делает lstat).
  def self.zero_fingerprint
    StrictModeGlobalLedger.missing_fingerprint
  end

  def self.evidence_tuple_matches?(record, ctx)
    %w[provider session_key raw_session_hash cwd project_dir].all? do |field|
      record.fetch(field) == ctx.fetch(field)
    end
  end

  # Anti-forgery min-age guard для confirmation markers.
  # Маркер, созданный в current user-prompt-submit hook (тот же
  # prompt_seq, что сейчас в prompt-sequence), допустим к consume
  # сразу — это легитимный "type confirm, immediately retry"
  # сценарий. Маркер с approval_prompt_seq != current допустим
  # только если он на диске уже не меньше min_age_sec секунд —
  # это защита от внешнего pre-existing forge файла, который
  # появился до старта strict-hook'а на ту же сессию.
  def self.fails_min_age?(marker, current_prompt_seq, min_age_sec, now: Time.now.utc)
    threshold = min_age_sec.to_i
    return false if threshold <= 0
    return false if marker.fetch("approval_prompt_seq") == current_prompt_seq

    created_at = Time.iso8601(marker.fetch("created_at"))
    (now - created_at) < threshold
  rescue ArgumentError, KeyError
    true
  end

  def self.prompt_marker_seq(marker)
    match = /\Aprompt-seq:([1-9][0-9]*)\z/.match(marker.to_s)
    match ? match[1].to_i : nil
  end

  def self.parse_time(value, field, errors)
    Time.iso8601(value)
  rescue ArgumentError, TypeError
    errors << "#{field} must parse as ISO-8601"
  end

  def self.sha256?(value)
    value.is_a?(String) && value.match?(SHA256_PATTERN)
  end

  def self.exact_fields(errors, record, expected, label)
    actual = record.keys.sort
    expected_sorted = expected.sort
    return if actual == expected_sorted

    missing = expected_sorted - actual
    extra = actual - expected_sorted
    details = []
    details << "missing #{missing.join(", ")}" unless missing.empty?
    details << "extra #{extra.join(", ")}" unless extra.empty?
    errors << "#{label} fields mismatch (#{details.join("; ")})"
  end
end
