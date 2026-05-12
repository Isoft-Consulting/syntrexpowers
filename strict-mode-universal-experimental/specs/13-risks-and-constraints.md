# 13. Risks And Constraints

Part of [Strict Mode Universal Experimental - Specification v0](../SPEC.md).


1. Codex hook API may be less documented or may change.
   Mitigation: fixture-driven adapter, provider version/build logging, and unverified events remaining discovery/log-only or activation-failing for enforcement; no fallback allow path is created by hook API uncertainty.

2. Codex `apply_patch` may not expose full patch content in PreToolUse.
   Mitigation: stop-time scan is authoritative for stub content; pre-tool patch scan is best-effort. This does not relax target-path proof: enforcing write-like events without normalized target paths still block before execution.

3. FDR challenge requires current-turn assistant text.
   Mitigation: enable challenge only after bounded current-turn extraction is fixture-proven from Stop payload fields, transcript path, or another verified runtime source; do not guess from raw transcripts or provider history.

4. Nested provider judge may fail or dirty normal provider session/history files due to session storage or sandbox restrictions.
   Mitigation: fixture-proven judge invocation, fixture-proven provider state isolation, `--ephemeral` only when supported by the installed Codex build, protected nested token guard, and audited semantic `unknown` that never disables artifact validation or other Stop gates.

5. Provider auto-detection can be wrong.
   Mitigation: installer passes `--provider`, payload cross-checking logs mismatches, `STRICT_PROVIDER` remains only a manual fixture/diagnostic override, and any provider resolution without installer-generated argv cannot create trusted state or enable enforcement; fixture tests cover both providers.

6. Blocking, denying, and injection output formats differ by provider.
   Mitigation: do not enable fail-closed gates or prompt injection until the matching decision-output contract is verified for the installed provider version/build.

7. Project opt-out files can be created by the agent.
   Mitigation: opt-outs are accepted only from baseline plus approval rules; current-turn creations are logged as attempted self-bypass, and opt-outs first seen after session start require explicit later user approval.

8. Agent tools can try to forge strict-mode runtime, state, or project config files.
   Mitigation: installed strict-mode runtime/state/config roots, including project `.strict-mode/`, are protected paths; direct provider-tool writes are blocked before confirmation or bypass state is trusted.

9. Agent tools can try to remove provider hooks from Claude/Codex config.
   Mitigation: provider hook config files are protected roots and included in protected-baseline integrity checks.

10. A compromised runtime cannot reliably detect itself.
   Mitigation: conservative pre-tool protected-path blocking is mandatory; integrity verification is only a backstop, and out-of-band same-account tampering is outside v0's trust boundary.

---
