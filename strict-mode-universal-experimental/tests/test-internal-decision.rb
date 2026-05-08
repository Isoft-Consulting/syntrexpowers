#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../tools/internal_decision_lib"
require_relative "../tools/fixture_readiness_lib"
require_relative "../tools/hook_entry_plan_lib"

$cases = 0
$failures = []

def record_failure(name, message)
  $failures << "#{name}: #{message}"
end

def assert(name, condition, message)
  $cases += 1
  record_failure(name, message) unless condition
end

def preflight(logical_event:, attempted: true, trusted: true, would_block: false, reason_code: "ok", preflight_hash: "0" * 64)
  {
    "logical_event" => logical_event,
    "attempted" => attempted,
    "trusted" => trusted,
    "would_block" => would_block,
    "reason_code" => reason_code,
    "preflight_hash" => preflight_hash
  }
end

# Базовое поведение allow при удачном preflight на pre-tool-use.
name = "pre-tool-use trusted attempted preflight allows"
decision = StrictModeInternalDecision.from_preflight(preflight(logical_event: "pre-tool-use"))
assert(name, decision["action"] == "allow", "expected allow, got #{decision["action"]}")
assert(name, decision["reason"] == "", "expected empty reason, got #{decision["reason"].inspect}")
assert(name, decision["metadata"]["logical_event"] == "pre-tool-use", "metadata logical_event mismatch")

# Untrusted preflight приводит к block с понятной причиной.
name = "untrusted preflight blocks with diagnostic"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "pre-tool-use", attempted: true, trusted: false, reason_code: "trust-failed")
)
assert(name, decision["action"] == "block", "expected block, got #{decision["action"]}")
assert(name, decision["reason"].include?("trust-failed"), "reason missing reason_code")

# would_block приводит к block.
name = "would_block preflight blocks"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "pre-tool-use", would_block: true, reason_code: "destructive")
)
assert(name, decision["action"] == "block", "expected block, got #{decision["action"]}")
assert(name, decision["reason"].include?("destructive"), "reason missing reason_code")

# Stop без attempted-preflight требует continuation block.
name = "stop without attempt requires continuation block"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "stop", attempted: false, reason_code: "no-attempt")
)
assert(name, decision["action"] == "block", "expected block, got #{decision["action"]}")
assert(name, decision["reason"].include?("provider continuation"), "reason missing continuation marker")

# Recursion guard: stop_hook_active=true пропускает follow-up Stop.
name = "stop_hook_active suppresses follow-up stop block"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "stop", attempted: false, reason_code: "no-attempt"),
  stop_hook_active: true
)
assert(name, decision["action"] == "allow", "expected allow on follow-up stop, got #{decision["action"]}")
assert(name, decision["reason"] == "", "expected empty reason on recursion-guard allow")

# Recursion guard работает и для subagent-stop.
name = "stop_hook_active suppresses follow-up subagent-stop block"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "subagent-stop", attempted: false, reason_code: "no-attempt"),
  stop_hook_active: true
)
assert(name, decision["action"] == "allow", "expected allow on follow-up subagent-stop")

# Recursion guard НЕ применяется к pre-tool-use (даже если флаг истинный).
name = "stop_hook_active does not bypass pre-tool-use blocking"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "pre-tool-use", would_block: true, reason_code: "destructive"),
  stop_hook_active: true
)
assert(name, decision["action"] == "block", "stop_hook_active must not bypass pre-tool-use block")

# Recursion guard НЕ применяется к permission-request (continuation, но не stop-loop).
name = "stop_hook_active does not bypass permission-request continuation"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "permission-request", attempted: false, reason_code: "no-attempt"),
  stop_hook_active: true
)
assert(name, decision["action"] == "block", "stop_hook_active must not affect permission-request guard")

# Trusted attempted preflight на stop без stop_hook_active тоже allow.
name = "trusted attempted stop allows without recursion guard"
decision = StrictModeInternalDecision.from_preflight(
  preflight(logical_event: "stop", attempted: true, trusted: true, would_block: false)
)
assert(name, decision["action"] == "allow", "expected allow, got #{decision["action"]}")

# Drift guard: BLOCKING_EVENTS в hook_entry_plan_lib и fixture_readiness_lib
# определены отдельно (избегаем кросс-зависимостей), но обязаны совпадать.
# Любое расхождение = баг конфигурации блокирующих событий.
name = "BLOCKING_EVENTS stay aligned across modules"
hook_set = StrictModeHookEntryPlan::BLOCKING_EVENTS.sort
readiness_set = StrictModeFixtureReadiness::BLOCKING_EVENTS.sort
assert(name, hook_set == readiness_set,
       "drift: hook_entry_plan #{hook_set.inspect} vs fixture_readiness #{readiness_set.inspect}")

# CONTINUATION_GUARD_EVENTS должно содержать все STOP_LIKE_EVENTS.
name = "CONTINUATION_GUARD_EVENTS is a superset of STOP_LIKE_EVENTS"
assert(name,
       (StrictModeInternalDecision::STOP_LIKE_EVENTS - StrictModeInternalDecision::CONTINUATION_GUARD_EVENTS).empty?,
       "stop-like events leaked outside continuation guard set")

if $failures.empty?
  puts "internal decision tests passed (#{$cases} cases)"
  exit 0
else
  warn $failures.join("\n")
  warn "internal decision tests FAILED (#{$failures.length} of #{$cases} cases)"
  exit 1
end
