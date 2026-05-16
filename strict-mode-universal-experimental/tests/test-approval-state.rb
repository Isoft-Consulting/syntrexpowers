#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"
require "time"
require "tmpdir"
require_relative "../tools/approval_state_lib"
require_relative "../tools/metadata_lib"

$cases = 0
$failures = []

def record_failure(name, message)
  $failures << "#{name}: #{message}"
end

def assert(name, condition, message)
  $cases += 1
  record_failure(name, message) unless condition
end

def marker(approval_prompt_seq:, created_at:)
  {
    "schema_version" => 1,
    "kind" => "destructive-confirm",
    "provider" => "codex",
    "session_key" => "test-session",
    "raw_session_hash" => "0" * 64,
    "cwd" => "/tmp/test",
    "project_dir" => "/tmp/test",
    "approval_hash" => "a" * 64,
    "pending_record_hash" => "b" * 64,
    "next_user_prompt_marker" => "prompt-seq:#{approval_prompt_seq}",
    "approval_prompt_seq" => approval_prompt_seq,
    "approval_log_record_hash" => "c" * 64,
    "source" => "user-prompt-hook",
    "created_at" => created_at,
    "expires_at" => "2099-01-01T00:00:00Z",
    "marker_hash" => "d" * 64
  }
end

now = Time.utc(2026, 5, 16, 12, 0, 0)

# Случай 1: min_age=0 — guard выключен, маркер всегда допустим.
assert(
  "min-age 0 disables guard for same prompt_seq",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: now.iso8601),
    1,
    0,
    now: now
  ),
  "expected fails_min_age? == false when min_age_sec == 0"
)

assert(
  "min-age 0 disables guard for cross-prompt fresh marker",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: now.iso8601),
    2,
    0,
    now: now
  ),
  "expected fails_min_age? == false when min_age_sec == 0 even cross-prompt"
)

# Случай 2: same prompt_seq — пропускаем guard, "type confirm + immediate retry".
assert(
  "same prompt_seq is consumable immediately regardless of age",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 7, created_at: now.iso8601),
    7,
    60,
    now: now
  ),
  "expected same-prompt marker to bypass min-age"
)

# Случай 3: different prompt_seq, маркер моложе порога — отказ.
assert(
  "different prompt_seq and young marker is rejected",
  StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: (now - 5).iso8601),
    2,
    30,
    now: now
  ),
  "expected pre-existing-style marker younger than min_age to be rejected"
)

# Случай 4: different prompt_seq, маркер старше порога — допускается.
assert(
  "different prompt_seq and aged marker passes",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: (now - 120).iso8601),
    2,
    30,
    now: now
  ),
  "expected aged cross-prompt marker to satisfy min-age"
)

# Случай 5: ровно min_age_sec — фактическая разница 30s ровно, threshold 30 — не меньше → пройдёт.
assert(
  "exactly min_age_sec is not rejected (uses strict <, not <=)",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: (now - 30).iso8601),
    2,
    30,
    now: now
  ),
  "expected (now - created_at) == min_age_sec to pass"
)

# Случай 6: malformed created_at — фейл-кloze; защищаемся.
assert(
  "malformed created_at fails closed",
  StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: "not-a-date"),
    2,
    30,
    now: now
  ),
  "expected malformed created_at to trigger fails_min_age? == true"
)

# Случай 7: maркер без поля created_at — KeyError → fails closed.
assert(
  "missing created_at fails closed",
  StrictModeApprovalState.fails_min_age?(
    { "approval_prompt_seq" => 1 },
    2,
    30,
    now: now
  ),
  "expected missing created_at to trigger fails_min_age? == true"
)

# Случай 8: min_age_sec как строка из runtime config (после .to_i это integer).
assert(
  "string min_age_sec is normalized to integer",
  StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: (now - 5).iso8601),
    2,
    "30",
    now: now
  ),
  "expected string min_age_sec '30' to be parsed via .to_i"
)

# Случай 9: отрицательный min_age_sec трактуется как 0.
assert(
  "negative min_age_sec disables guard",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: now.iso8601),
    2,
    -10,
    now: now
  ),
  "expected negative min_age_sec to be treated as disabled"
)

# consumed_audit_evidence_since: пустой destructive-log → пустая
# evidence-выдача, не crash. Покрывает rescue ветку.
Dir.mktmpdir("strict-evidence-") do |dir|
  state_root = Pathname.new(dir)
  ctx = {
    "provider" => "codex",
    "session_key" => "test-session",
    "raw_session_hash" => "0" * 64,
    "cwd" => "/tmp/test",
    "project_dir" => "/tmp/test"
  }
  evidence = StrictModeApprovalState.consumed_audit_evidence_since(
    state_root,
    ctx,
    "1970-01-01T00:00:00Z",
    Time.now.utc.iso8601
  )
  assert(
    "consumed_audit_evidence_since returns empty array when destructive log absent",
    evidence == [],
    "expected [], got #{evidence.inspect}"
  )
end

# consumed_audit_evidence_since: malformed JSONL (partial write race
# или реальная corruption) → возвращает sentinel с
# kind=approval-evidence-read-failed (не [] — иначе Stop не отличит
# от законного пустого turn'а).
Dir.mktmpdir("strict-evidence-") do |dir|
  state_root = Pathname.new(dir)
  log = StrictModeApprovalState.destructive_log_path(state_root)
  log.write("{\n\n")
  ctx = {
    "provider" => "codex",
    "session_key" => "test-session",
    "raw_session_hash" => "0" * 64,
    "cwd" => "/tmp/test",
    "project_dir" => "/tmp/test"
  }
  evidence = StrictModeApprovalState.consumed_audit_evidence_since(
    state_root,
    ctx,
    "1970-01-01T00:00:00Z"
  )
  assert(
    "consumed_audit_evidence_since emits read-failed sentinel on corrupted log",
    evidence.length == 1 && evidence.first["kind"] == "approval-evidence-read-failed",
    "expected one sentinel with kind=approval-evidence-read-failed, got #{evidence.inspect}"
  )
  assert(
    "read-failed sentinel exposes approval_hash sentinel (consumers safe to fetch)",
    evidence.first["approval_hash"] == "0" * 64,
    "expected ZERO_HASH approval_hash on read-failed sentinel, got #{evidence.first.inspect}"
  )
end

# consumed_audit_evidence_since cap: если matched > cap, отдаём
# последние cap записей плюс truncation header.
require_relative "../tools/global_ledger_lib"
Dir.mktmpdir("strict-evidence-") do |dir|
  state_root = Pathname.new(dir)
  ctx = {
    "provider" => "codex",
    "session_key" => "cap-session",
    "raw_session_hash" => "0" * 64,
    "cwd" => "/tmp/test",
    "project_dir" => "/tmp/test"
  }
  log = StrictModeApprovalState.destructive_log_path(state_root)
  missing_fingerprint = StrictModeGlobalLedger.fingerprint(state_root.join("missing-#{SecureRandom.hex(4)}"))
  previous_hash = "0" * 64
  base_ts = Time.utc(2026, 5, 16, 12, 0, 0)
  10.times do |i|
    record = {
      "schema_version" => 1,
      "log" => "destructive",
      "action" => "consumed",
      "provider" => "codex",
      "session_key" => "cap-session",
      "raw_session_hash" => "0" * 64,
      "cwd" => "/tmp/test",
      "project_dir" => "/tmp/test",
      "approval_hash" => format("%064x", i + 1),
      "pending_record_hash" => format("%064x", 0x1000 + i),
      "next_user_prompt_marker" => "prompt-seq:1",
      "prompt_seq" => 0,
      "source" => "pre-tool-hook",
      "ts" => (base_ts + i).iso8601,
      "previous_record_hash" => previous_hash,
      "command_hash" => format("%064x", 0x2000 + i),
      "command_hash_source" => "shell-string",
      "marker_hash" => format("%064x", 0x3000 + i),
      "active_marker_path" => "/tmp/marker-#{i}",
      "consumed_tombstone_path" => "/tmp/tombstone-#{i}",
      "marker_pre_rename_fingerprint" => missing_fingerprint,
      "tombstone_fingerprint" => missing_fingerprint,
      "record_hash" => ""
    }
    record["record_hash"] = StrictModeMetadata.hash_record(record, "record_hash")
    previous_hash = record["record_hash"]
    log.open("a") { |f| f.write(JSON.generate(record) + "\n") }
  end
  evidence = StrictModeApprovalState.consumed_audit_evidence_since(
    state_root,
    ctx,
    "1970-01-01T00:00:00Z",
    nil,
    cap: 3
  )
  assert(
    "consumed_audit_evidence_since cap returns truncation header + last N",
    evidence.length == 4 && evidence.first["truncated_count"] == 7,
    "expected 4 entries (header+3) with truncated_count=7, got #{evidence.inspect}"
  )
  assert(
    "consumed_audit_evidence_since cap header carries truncation kind",
    evidence.first["kind"] == "approval-evidence-truncated",
    "expected truncation header kind, got #{evidence.first.inspect}"
  )
  assert(
    "consumed_audit_evidence_since cap header has approval_hash sentinel (consumers safe to fetch)",
    evidence.first["approval_hash"] == "0" * 64,
    "expected ZERO_HASH approval_hash on truncation header, got #{evidence.first.inspect}"
  )
  assert(
    "consumed_audit_evidence_since cap keeps newest entries",
    evidence.last["approval_hash"] == format("%064x", 10),
    "expected last approval_hash to be hash of i=9, got #{evidence.last.inspect}"
  )

  # Невалидный cap (0, nil, negative, string) — fallback к умолчанию.
  [0, nil, -5, "abc"].each do |bad_cap|
    evidence_bad = StrictModeApprovalState.consumed_audit_evidence_since(
      state_root,
      ctx,
      "1970-01-01T00:00:00Z",
      nil,
      cap: bad_cap
    )
    expected_min = StrictModeApprovalState::TURN_BASELINE_APPROVAL_EVIDENCE_CAP
    overflow = 10 > expected_min ? 10 - expected_min : 0
    expected_length = overflow.positive? ? expected_min + 1 : 10
    assert(
      "consumed_audit_evidence_since falls back on invalid cap #{bad_cap.inspect}",
      evidence_bad.length == expected_length,
      "with cap=#{bad_cap.inspect} expected #{expected_length} entries (default cap), got #{evidence_bad.length}"
    )
  end
end

# fails_min_age? при cap-параметре передаётся как Integer 0 → guard off
assert(
  "integer 0 min_age_sec disables guard explicitly",
  !StrictModeApprovalState.fails_min_age?(
    marker(approval_prompt_seq: 1, created_at: now.iso8601),
    2,
    0,
    now: now
  ),
  "expected Integer 0 to disable guard"
)

# expire_pending_decision: чистая функция idempotency-логики
# (extract'нута из expire_pending_record!). Покрывает 4 branch'а:
# proceed, skip_tombstone_only, skip_ambiguous, skip_nothing.
Dir.mktmpdir("strict-expire-decision-") do |dir|
  pending = Pathname.new(dir).join("pending-destructive-codex-x-aaa.json")
  tombstone = Pathname.new(dir).join("expired-pending-destructive-codex-x-aaa.json")

  # nothing: ни pending, ни tombstone → skip_nothing
  assert(
    "expire_pending_decision returns skip_nothing when both absent",
    StrictModeApprovalState.expire_pending_decision(pending, tombstone) == :skip_nothing,
    "expected :skip_nothing"
  )

  # proceed: только pending → :proceed
  pending.write("{}")
  assert(
    "expire_pending_decision returns proceed when pending exists and tombstone absent",
    StrictModeApprovalState.expire_pending_decision(pending, tombstone) == :proceed,
    "expected :proceed"
  )

  # ambiguous: оба → :skip_ambiguous (защита от затирания старого tombstone)
  tombstone.write("{}")
  assert(
    "expire_pending_decision returns skip_ambiguous when both exist",
    StrictModeApprovalState.expire_pending_decision(pending, tombstone) == :skip_ambiguous,
    "expected :skip_ambiguous"
  )

  # tombstone_only: после успешного sweep'a — pending удалён, tombstone остался → idempotent skip
  pending.unlink
  assert(
    "expire_pending_decision returns skip_tombstone_only when only tombstone present",
    StrictModeApprovalState.expire_pending_decision(pending, tombstone) == :skip_tombstone_only,
    "expected :skip_tombstone_only"
  )

  # symlink на pending или tombstone не считается валидным (rejected
  # protections against attacker pre-creating symlink to redirect rename).
  pending_target = Pathname.new(dir).join("target.json")
  pending_target.write("{}")
  pending.make_symlink(pending_target)
  tombstone.unlink
  assert(
    "expire_pending_decision rejects pending symlink (skip_nothing)",
    StrictModeApprovalState.expire_pending_decision(pending, tombstone) == :skip_nothing,
    "expected :skip_nothing on symlink pending"
  )
  pending.unlink
end

if $failures.empty?
  puts "approval-state: #{$cases} cases ok"
else
  $failures.each { |failure| warn failure }
  warn "approval-state: #{$failures.size}/#{$cases} cases failed"
  exit 1
end
