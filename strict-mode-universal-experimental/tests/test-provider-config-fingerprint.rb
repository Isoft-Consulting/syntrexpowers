#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "tmpdir"
require_relative "../tools/provider_config_fingerprint_lib"

ZERO_HASH = "0" * 64
$cases = 0
$failures = []

def record_failure(name, message, detail = "")
  $failures << "#{name}: #{message}#{detail.empty? ? "" : "\n#{detail}"}"
end

def assert(name, condition, message, detail = "")
  record_failure(name, message, detail) unless condition
end

def with_tmp
  Dir.mktmpdir("fingerprint-") { |dir| yield Pathname.new(dir).realpath }
end

$cases += 1
name = "missing file returns zero hash"
with_tmp do |dir|
  missing = dir.join(".claude/settings.json")
  assert(name, StrictModeProviderConfigFingerprint.content_sha256(missing, "provider-config", "claude") == ZERO_HASH, "missing path should hash to zero")
end

$cases += 1
name = "claude settings.json content hash is raw file content"
with_tmp do |dir|
  claude_dir = dir.join(".claude")
  claude_dir.mkpath
  settings = claude_dir.join("settings.json")
  payload = JSON.pretty_generate({ "theme" => "dark-ansi", "hooks" => {} }) + "\n"
  settings.write(payload)
  computed = StrictModeProviderConfigFingerprint.content_sha256(settings, "provider-config", "claude")
  expected = Digest::SHA256.hexdigest(payload)
  assert(name, computed == expected, "Claude settings.json must hash to raw file content — no mutable mask exists for Claude", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "claude settings.json is not a mutable_provider_state_record"
with_tmp do |dir|
  claude_dir = dir.join(".claude")
  claude_dir.mkpath
  settings = claude_dir.join("settings.json")
  settings.write("{}\n")
  assert(name, !StrictModeProviderConfigFingerprint.mutable_provider_state_record?(settings.to_s, "provider-config", "claude"), "Claude provider-config must not be classified as mutable trust-state")
end

$cases += 1
name = "codex config.toml strips [hooks.state] before hashing"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  stable = "[features]\nhooks = true\n"
  full = stable + "\n[hooks.state]\n\n[hooks.state.\"key\"]\ntrusted_hash = \"sha256:#{"a" * 64}\"\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  expected = Digest::SHA256.hexdigest(stable)
  assert(name, computed == expected, "Codex config.toml must strip [hooks.state] tables before hashing", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "codex config.toml without hooks.state hashes raw content"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  content = "[features]\nhooks = true\n"
  config.write(content)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  expected = Digest::SHA256.hexdigest(content)
  assert(name, computed == expected, "Codex config.toml without hooks.state must hash to raw content", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "codex config.toml is a mutable_provider_state_record"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  config.write("[features]\n")
  assert(name, StrictModeProviderConfigFingerprint.mutable_provider_state_record?(config.to_s, "provider-config", "codex"), "Codex config.toml must be classified as mutable trust-state")
end

$cases += 1
name = "codex hooks.json is not a mutable_provider_state_record"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  hooks = codex_dir.join("hooks.json")
  hooks.write("{}\n")
  assert(name, !StrictModeProviderConfigFingerprint.mutable_provider_state_record?(hooks.to_s, "provider-config", "codex"), "Codex hooks.json must remain fully hash-protected")
end

$cases += 1
name = "non-provider-config kind is never a mutable_provider_state_record"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  config.write("[features]\n")
  %w[runtime-config protected-config install-manifest fixture-manifest runtime-file].each do |kind|
    assert(name, !StrictModeProviderConfigFingerprint.mutable_provider_state_record?(config.to_s, kind, "codex"), "kind=#{kind} must not classify as mutable trust-state regardless of path")
  end
end

$cases += 1
name = "Codex hooks.state stripped when interleaved with stable tables"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  full = "[features]\nhooks = true\n\n[hooks.state.\"a\"]\ntrusted_hash = \"sha256:#{"a" * 64}\"\n\n[projects.\"/var/www\"]\ntrust_level = \"trusted\"\n\n[hooks.state.\"b\"]\ntrusted_hash = \"sha256:#{"b" * 64}\"\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  # Blank line right before [hooks.state.*] is popped from output (see
  # `output.pop while skip && output.last&.strip == ""` in
  # provider_config_fingerprint_lib.rb). So expected stable text has the
  # `[projects.*]` block sitting directly after `hooks = true` with
  # no separating blank line.
  expected_stable = "[features]\nhooks = true\n[projects.\"/var/www\"]\ntrust_level = \"trusted\"\n"
  expected = Digest::SHA256.hexdigest(expected_stable)
  assert(name, computed == expected, "interleaved hooks.state blocks must all be stripped while keeping intervening stable tables intact", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "Bare [hooks] table (not in hooks.state namespace) is preserved"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  full = "[hooks]\nenabled = true\n\n[hooks.state]\nkey = \"value\"\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  expected_stable = "[hooks]\nenabled = true\n"
  expected = Digest::SHA256.hexdigest(expected_stable)
  assert(name, computed == expected, "bare [hooks] must be preserved, only [hooks.state]/[hooks.state.*] stripped", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "Comments before [hooks.state] block are preserved"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  full = "[features]\nhooks = true\n# stable comment above mutable trust state\n[hooks.state]\nkey = \"value\"\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  expected_stable = "[features]\nhooks = true\n# stable comment above mutable trust state\n"
  expected = Digest::SHA256.hexdigest(expected_stable)
  assert(name, computed == expected, "comments before hooks.state must remain in hash", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "[[hooks.state]] array-of-tables form IS stripped (defense-in-depth for future Codex changes)"
# strip_codex_mutable_state_tables now recognises both `[X]` and `[[X]]` forms.
# Codex CLI does not currently emit array-of-tables for hooks.state per Bachynskyi's
# 5d10fef commit message, but the broader regex keeps the "any hooks.state-
# namespaced mutable trust-state block is not part of the stable content hash"
# invariant robust against future Codex changes.
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  full = "[features]\nhooks = true\n[[hooks.state]]\nfoo = 1\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  expected = Digest::SHA256.hexdigest("[features]\nhooks = true\n")
  assert(name, computed == expected, "array-of-tables [[hooks.state]] must also be stripped", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "[hooks.state] as the FIRST and ONLY table yields empty stripped content"
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  full = "[hooks.state]\nkey = \"value\"\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  expected = Digest::SHA256.hexdigest("")
  assert(name, computed == expected, "file containing only hooks.state must hash to empty content", "computed=#{computed} expected=#{expected}")
end

$cases += 1
name = "Quoted keys with embedded `]` are a known regex limitation"
# Regex `[^\]]+` stops at the first `]` regardless of TOML quoting. For
# `[hooks.state."key]inner"]` the captured table name is `hooks.state."key`,
# which does not equal "hooks.state" and does not start with "hooks.state."
# either, so the block is NOT classified as mutable state and stays in the
# hash. Codex does not emit such keys today; a proper fix would require a
# real TOML parser inside this fingerprint helper. This test pins the
# limitation so a future regression of TOML-aware parsing is visible.
with_tmp do |dir|
  codex_dir = dir.join(".codex")
  codex_dir.mkpath
  config = codex_dir.join("config.toml")
  full = "[features]\nhooks = true\n[hooks.state.\"key]inner\"]\ntrusted = \"sha256:#{"c" * 64}\"\n"
  config.write(full)
  computed = StrictModeProviderConfigFingerprint.content_sha256(config, "provider-config", "codex")
  # Current behaviour: NOT stripped (limitation), entire file remains in hash.
  expected = Digest::SHA256.hexdigest(full)
  assert(name, computed == expected, "current contract: quoted keys with embedded `]` are NOT recognized as hooks.state (regex limitation, pinned for visibility)", "computed=#{computed} expected=#{expected}")
end

if $failures.empty?
  puts "provider config fingerprint tests passed (#{$cases} cases)"
else
  warn "provider config fingerprint tests: #{$failures.length} failures"
  warn $failures.join("\n\n")
  exit 1
end
