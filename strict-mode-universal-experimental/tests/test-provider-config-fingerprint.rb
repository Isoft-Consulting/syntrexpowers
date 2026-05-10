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
  stable = "[features]\ncodex_hooks = true\n"
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
  content = "[features]\ncodex_hooks = true\n"
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

if $failures.empty?
  puts "provider config fingerprint tests passed (#{$cases} cases)"
else
  warn "provider config fingerprint tests: #{$failures.length} failures"
  warn $failures.join("\n\n")
  exit 1
end
