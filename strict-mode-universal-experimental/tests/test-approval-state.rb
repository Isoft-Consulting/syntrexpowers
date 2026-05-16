#!/usr/bin/env ruby
# frozen_string_literal: true

require "time"
require_relative "../tools/approval_state_lib"

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

if $failures.empty?
  puts "approval-state: #{$cases} cases ok"
else
  $failures.each { |failure| warn failure }
  warn "approval-state: #{$failures.size}/#{$cases} cases failed"
  exit 1
end
