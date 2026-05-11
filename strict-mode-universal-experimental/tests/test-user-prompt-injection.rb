#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "../tools/protected_baseline_lib"

ROOT = Pathname.new(__dir__).parent.expand_path
INSTALL = ROOT.join("install.sh")

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def assert(name, condition, message, output = "")
  record_failure(name, message, output) unless condition
end

def assert_no_stacktrace(name, output)
  return unless output.match?(/(^|\n)\S+\.rb:\d+:in `/) || output.include?("\n\tfrom ")

  record_failure(name, "unexpected Ruby stacktrace", output)
end

def run_cmd(env, *argv)
  stdout, stderr, status = Open3.capture3(env, *argv.map(&:to_s))
  [status.exitstatus, stdout + stderr]
end

def with_install_claude
  $cases += 1
  Dir.mktmpdir("strict-prompt-inject-") do |dir|
    root = Pathname.new(dir).realpath
    home = root.join("home")
    install_root = root.join("strict root")
    project = root.join("project")
    project.join(".strict-mode").mkpath
    home.join(".claude").mkpath
    home.join(".codex").mkpath
    home.join(".claude/settings.json").write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
    home.join(".codex/hooks.json").write(JSON.pretty_generate({ "hooks" => {} }) + "\n")
    home.join(".codex/config.toml").write("[features]\nexisting = true\n")

    # Pre-stage injection content BEFORE install — installer's template copy
    # skips files that already exist (`next if path.exist?` in
    # install_runtime#staged_config_dir), so the populated file survives
    # and the protected baseline records its content_sha256.
    config_root = install_root.join("config")
    config_root.mkpath
    yield_setup = block_given? ? yield(:setup) : nil
    if yield_setup.is_a?(String)
      config_root.join("user-prompt-injection.md").write(yield_setup)
      File.chmod(0o600, config_root.join("user-prompt-injection.md"))
    end

    status, output = run_cmd({ "HOME" => home.to_s }, INSTALL, "--provider", "claude", "--install-root", install_root)
    assert_no_stacktrace("install fixture", output)
    raise "install failed: #{output}" unless status.zero?

    yield :test, root, home, install_root, install_root.join("state"), project
  end
end

def run_strict_hook(env, install_root, provider, logical_event, payload)
  hook_path = install_root.join("active/bin/strict-hook")
  raise "hook binary missing: #{hook_path}" unless hook_path.file?

  Open3.capture3(env, hook_path.to_s, "--provider", provider, logical_event, stdin_data: payload)
end

def claude_user_prompt_payload(project)
  JSON.generate({
    "session_id" => "11111111-2222-3333-4444-555555555555",
    "transcript_path" => project.join(".claude/projects/test.jsonl").to_s,
    "cwd" => project.to_s,
    "hook_event_name" => "UserPromptSubmit",
    "prompt" => "test prompt"
  })
end

# --- Case 1: injection populated → stdout contains content ---
INJECTION_CONTENT = "TEST INJECTION RULES\n1. Marker line one\n2. Marker line two\n"

# Explicit STRICT_MODE_NESTED unset so cases that rely on it being absent
# don't false-pass when the test driver session happens to have it set.
# Open3.capture3 treats a nil value in env hash as "remove from subprocess
# environment", so subprocess sees no STRICT_MODE_NESTED regardless of
# parent env.
def base_env(home, state_root, project)
  {
    "HOME" => home.to_s,
    "STRICT_STATE_ROOT" => state_root.to_s,
    "STRICT_PROJECT_DIR" => project.to_s,
    "STRICT_MODE_NESTED" => nil
  }
end

with_install_claude do |phase, *args|
  case phase
  when :setup
    next INJECTION_CONTENT
  when :test
    _root, home, install_root, state_root, project = args
    name = "user-prompt-submit emits injection content when config populated and baseline trusted"
    env = base_env(home, state_root, project)
    stdout, stderr, status = run_strict_hook(env, install_root, "claude", "user-prompt-submit", claude_user_prompt_payload(project))
    assert_no_stacktrace(name, stdout + stderr)
    assert(name, status.exitstatus.zero?, "strict-hook must exit 0, got #{status.exitstatus}", stdout + stderr)
    assert(name, stdout.include?("TEST INJECTION RULES"), "stdout must contain injection content marker line 0", stdout.inspect)
    assert(name, stdout.include?("Marker line one"), "stdout must contain marker line 1", stdout.inspect)
    assert(name, stdout.include?("Marker line two"), "stdout must contain marker line 2", stdout.inspect)
    assert(name, stdout.end_with?("\n"), "stdout must end with newline", stdout.inspect)
  end
end

# --- Case 2: STRICT_MODE_NESTED=1 suppresses injection ---
with_install_claude do |phase, *args|
  case phase
  when :setup
    next INJECTION_CONTENT
  when :test
    _root, home, install_root, state_root, project = args
    name = "user-prompt-submit suppresses injection when STRICT_MODE_NESTED=1"
    env = base_env(home, state_root, project).merge("STRICT_MODE_NESTED" => "1")
    stdout, stderr, status = run_strict_hook(env, install_root, "claude", "user-prompt-submit", claude_user_prompt_payload(project))
    assert_no_stacktrace(name, stdout + stderr)
    assert(name, status.exitstatus.zero?, "strict-hook must exit 0", stdout + stderr)
    assert(name, !stdout.include?("TEST INJECTION RULES"), "STRICT_MODE_NESTED guard must suppress injection content", stdout.inspect)
  end
end

# --- Case 3: empty injection file → no stdout output ---
with_install_claude do |phase, *args|
  case phase
  when :setup
    next ""
  when :test
    _root, home, install_root, state_root, project = args
    name = "user-prompt-submit emits no injection content when file is empty (default template)"
    env = base_env(home, state_root, project)
    stdout, stderr, status = run_strict_hook(env, install_root, "claude", "user-prompt-submit", claude_user_prompt_payload(project))
    assert_no_stacktrace(name, stdout + stderr)
    assert(name, status.exitstatus.zero?, "strict-hook must exit 0", stdout + stderr)
    assert(name, !stdout.include?("INJECTION RULES"), "empty config must produce no injection markers in stdout", stdout.inspect)
  end
end

# --- Case 4: tampered injection file → baseline untrusted → no injection ---
with_install_claude do |phase, *args|
  case phase
  when :setup
    next INJECTION_CONTENT
  when :test
    _root, home, install_root, state_root, project = args
    name = "user-prompt-submit suppresses injection when config tampered after install (baseline untrusted)"
    # Mutate the protected config AFTER install so baseline integrity fails.
    tampered_path = install_root.join("config/user-prompt-injection.md")
    tmp = tampered_path.dirname.join(".#{tampered_path.basename}.tmp")
    tmp.write("TAMPERED CONTENT NOT IN BASELINE\n")
    File.chmod(0o600, tmp)
    File.rename(tmp, tampered_path)
    env = base_env(home, state_root, project)
    stdout, stderr, status = run_strict_hook(env, install_root, "claude", "user-prompt-submit", claude_user_prompt_payload(project))
    assert_no_stacktrace(name, stdout + stderr)
    assert(name, status.exitstatus.zero?, "strict-hook must exit 0 even when injection skipped", stdout + stderr)
    assert(name, !stdout.include?("TAMPERED CONTENT"), "tampered content must NOT be emitted (baseline untrusted blocks injection)", stdout.inspect)
    assert(name, !stdout.include?("TEST INJECTION RULES"), "original content must also not appear since baseline is untrusted", stdout.inspect)
  end
end

if $failures.empty?
  puts "user-prompt-injection hook tests passed (#{$cases} cases)"
else
  warn "user-prompt-injection hook tests: #{$failures.length} failures"
  warn $failures.join("\n\n")
  exit 1
end
