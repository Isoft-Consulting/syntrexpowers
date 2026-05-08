#!/usr/bin/env ruby
# frozen_string_literal: true

module StrictModeInternalDecision
  extend self

  STOP_LIKE_EVENTS = %w[stop subagent-stop].freeze
  CONTINUATION_GUARD_EVENTS = (STOP_LIKE_EVENTS + %w[permission-request]).freeze

  # Превращает preflight-результат в internal-decision для bin/strict-hook.
  # Recursion-guard: при follow-up Stop/SubagentStop с stop_hook_active=true
  # пропускаем block, чтобы провайдер не зациклился на собственном блоке
  # (см. specs/06-decision-contract.md:58).
  def from_preflight(preflight, stop_hook_active: false)
    logical_event = preflight.fetch("logical_event")
    stop_recursion = stop_hook_active && STOP_LIKE_EVENTS.include?(logical_event)
    block_reason = if stop_recursion
                     nil
                   elsif preflight.fetch("attempted") && !preflight.fetch("trusted")
                     "strict-mode could not trust preflight: #{preflight.fetch("reason_code")}"
                   elsif preflight.fetch("would_block")
                     "strict-mode blocked operation: #{preflight.fetch("reason_code")}"
                   elsif CONTINUATION_GUARD_EVENTS.include?(logical_event) &&
                         preflight.fetch("attempted") == false
                     "strict-mode #{logical_event} guard requires provider continuation"
                   end
    action = block_reason ? "block" : "allow"
    {
      "schema_version" => 1,
      "action" => action,
      "reason" => block_reason || "",
      "severity" => block_reason ? "error" : "info",
      "additional_context" => "",
      "metadata" => {
        "logical_event" => logical_event,
        "reason_code" => preflight.fetch("reason_code"),
        "preflight_hash" => preflight.fetch("preflight_hash")
      }
    }
  end
end
