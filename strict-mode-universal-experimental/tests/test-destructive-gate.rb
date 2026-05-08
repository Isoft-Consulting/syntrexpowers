#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"
require_relative "../tools/destructive_gate_lib"
require_relative "../tools/protected_config_lib"

$cases = 0
$failures = []

def record_failure(name, message, output = "")
  $failures << "#{name}: #{message}\n#{output}"
end

def write_file(path, bytes = "data\n")
  path.dirname.mkpath
  path.write(bytes)
  path
end

def destructive_records(bytes)
  result = StrictModeProtectedConfig.parse_bytes(bytes, kind: "destructive-patterns")
  raise "invalid destructive fixture: #{result.inspect}" unless result.fetch("trusted")

  result.fetch("records")
end

def with_project
  $cases += 1
  Dir.mktmpdir("strict-destructive-gate-") do |dir|
    root = Pathname.new(dir).realpath
    project = root.join("project")
    cwd = project.join("src")
    home = root.join("home")
    install = root.join("strict-install")
    [cwd, home, project.join(".strict-mode"), install.join("active/bin"), install.join("config"), install.join("state"), install.join("core"), install.join("lib"), install.join("providers")].each(&:mkpath)
    write_file(install.join("active/bin/strict-fdr"), "#!/usr/bin/env sh\n")
    write_file(install.join("active/bin/strict-hook"), "#!/usr/bin/env sh\n")
    write_file(install.join("config/runtime.env"), "STRICT_CAPTURE_RAW_PAYLOADS=0\n")
    protected_roots = [
      install,
      install.join("active"),
      install.join("config"),
      install.join("state"),
      project.join(".strict-mode")
    ]
    yield root, project, cwd, home, install, protected_roots
  end
end

def classify(tool, project:, cwd:, home:, install:, protected_roots:, destructive_patterns: [], protected_inodes: [])
  StrictModeDestructiveGate.classify_tool(
    tool,
    cwd: cwd,
    project_dir: project,
    protected_roots: protected_roots,
    protected_inodes: protected_inodes,
    destructive_patterns: destructive_patterns,
    home: home,
    install_root: install
  )
end

def shell_result(command, **kwargs)
  classify({ "kind" => "shell", "command" => command }, **kwargs)
end

def expect_result(name, result, decision, reason_code)
  return if result.fetch("decision") == decision && result.fetch("reason_code") == reason_code

  record_failure(name, "expected #{decision}/#{reason_code}, got #{result.inspect}")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "read-only shell command passes"
  result = shell_result("ls -la .", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "allow", "shell-read-only-or-unmatched")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "safe project redirect has proven non-protected target"
  project.join("build").mkpath
  result = shell_result("printf x > ../build/out.txt", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "allow", "shell-read-only-or-unmatched")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "safe shell mutator with proven project target allows"
  project.join("build").mkpath
  result = shell_result("touch ../build/generated.txt", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "allow", "shell-read-only-or-unmatched")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "dynamic shell write targets block as unknown"
  ["printf x > $TMPDIR/out.txt", "printf x > \"$(echo ../build/out.txt)\"", "rm *.tmp"].each do |command|
    result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
    expect_result("#{name}: #{command}", result, "block", "unknown-write-target")
  end
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "rm -rf root destructive pattern blocks"
  patterns = destructive_records("shell-ere rm[[:space:]]+-rf[[:space:]]+/\n")
  result = shell_result("rm -rf /", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots, destructive_patterns: patterns)
  expect_result(name, result, "block", "destructive-command")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "canonical destructive shell examples block"
  patterns = destructive_records(<<~TEXT)
    shell-ere git[[:space:]]+reset[[:space:]]+--hard
    shell-ere push[[:space:]].*--force
    shell-ere DROP[[:space:]]+TABLE
  TEXT
  ["git reset --hard HEAD", "git push --force origin main", "psql -c \"DROP TABLE users\""].each do |command|
    result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots, destructive_patterns: patterns)
    expect_result("#{name}: #{command}", result, "block", "destructive-command")
  end
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "argv-token destructive pattern blocks literal rm"
  patterns = destructive_records("argv-token rm\n")
  result = shell_result("rm tmp/file", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots, destructive_patterns: patterns)
  expect_result(name, result, "block", "destructive-command")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell redirect to protected runtime config blocks"
  result = shell_result("printf x > #{install.join('config/runtime.env')}", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "pipeline tee to protected runtime config blocks"
  result = shell_result("printf x | tee #{install.join('config/runtime.env')}", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "write-capable utilities to protected roots block"
  protected_file = install.join("config/runtime.env")
  [
    "touch #{protected_file}",
    "dd if=/dev/zero of=#{protected_file} bs=1 count=1",
    "rsync ../README.md #{install.join('state/copy')}",
    "zip #{install.join('state/archive.zip')} ../README.md"
  ].each do |command|
    result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
    expect_result("#{name}: #{command}", result, "block", "protected-root")
  end
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell redirect through final symlink blocks without inode proof"
  link = cwd.join("runtime-env-link")
  link.make_symlink(install.join("config/runtime.env"))
  result = shell_result("printf x > runtime-env-link", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell wrappers cannot hide protected writes"
  protected_file = install.join("config/runtime.env")
  [
    "env STRICT_ENV=1 touch #{protected_file}",
    "sudo touch #{protected_file}",
    "command touch #{protected_file}",
    "find #{install.join('config')} -delete"
  ].each do |command|
    result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
    expect_result("#{name}: #{command}", result, "block", "protected-root")
  end
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "relative traversal into project strict-mode blocks"
  result = shell_result("printf x > ../.strict-mode/disabled", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "runtime strict-hook execution blocks"
  result = shell_result("#{install.join('active/bin/strict-hook')} --provider codex stop", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-runtime-execution")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "env wrapper cannot hide runtime execution"
  result = shell_result("env STRICT_ENV=1 #{install.join('active/bin/strict-hook')} --provider codex stop", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-runtime-execution")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell substitution cannot hide runtime execution"
  hook = install.join("active/bin/strict-hook")
  escaped_hook = hook.to_s.gsub(" ", "\\ ")
  [
    "echo $(#{hook} --provider codex stop)",
    "echo $(#{escaped_hook} --provider codex stop)",
    "echo `#{hook} --provider codex stop`",
    "cat <(#{hook} --provider codex stop)"
  ].each do |command|
    result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
    expect_result("#{name}: #{command}", result, "block", "protected-runtime-execution")
  end
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "single-quoted substitution-looking runtime path remains read-only"
  command = "printf '%s\\n' '$(#{install.join('active/bin/strict-hook')} --provider codex stop)'"
  result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "allow", "shell-read-only-or-unmatched")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "runtime path argument inside substitution is not treated as runtime execution"
  command = "echo $(printf '%s' #{install.join('active/bin/strict-hook')})"
  result = shell_result(command, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "allow", "shell-read-only-or-unmatched")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell substitution nested protected write blocks"
  result = shell_result("echo $(touch #{install.join('config/runtime.env')})", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell substitution nested script wrapper blocks unknown write target"
  result = shell_result("echo $(sh -c 'touch generated.txt')", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "unknown-write-target")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell substitution nested destructive pattern blocks"
  patterns = destructive_records("shell-ere git[[:space:]]+reset[[:space:]]+--hard\n")
  result = shell_result("echo $(git reset --hard HEAD)", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots, destructive_patterns: patterns)
  expect_result(name, result, "block", "destructive-command")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "env-prefixed strict-fdr import is not trusted exception"
  write_file(project.join("review.md"), "# review\n")
  result = shell_result("STRICT_ENV=1 #{install.join('active/bin/strict-fdr')} import -- ../review.md", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-runtime-execution")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "exact strict-fdr import is unavailable until artifact importer is ready"
  write_file(project.join("review.md"), "# review\n")
  result = shell_result("\"#{install.join('active/bin/strict-fdr')}\" import -- ../review.md", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "trusted-import-unavailable")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "direct write to protected runtime config blocks"
  result = classify({ "kind" => "write", "file_path" => install.join("config/runtime.env").to_s }, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "direct write through final symlink blocks without inode proof"
  link = cwd.join("runtime-env-link")
  link.make_symlink(install.join("config/runtime.env"))
  result = classify({ "kind" => "write", "file_path" => link.to_s }, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "write-like direct tool without target blocks"
  result = classify({ "kind" => "write" }, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "protected-target-unknown")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "direct write to protected hardlink alias blocks"
  protected_file = install.join("config/runtime.env")
  hardlink = cwd.join("runtime-env-hardlink")
  File.link(protected_file, hardlink)
  stat = protected_file.stat
  result = classify(
    { "kind" => "write", "file_path" => hardlink.to_s },
    project: project,
    cwd: cwd,
    home: home,
    install: install,
    protected_roots: protected_roots,
    protected_inodes: [{ "dev" => stat.dev, "inode" => stat.ino }]
  )
  expect_result(name, result, "block", "protected-root")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "direct write to safe project file allows"
  result = classify({ "kind" => "write", "file_path" => cwd.join("app.rb").to_s }, project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "allow", "write-targets-disjoint")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "unterminated shell quote blocks as parse error"
  result = shell_result("printf 'x", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "shell-parse-error")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "redirect without target blocks as parse error"
  result = shell_result("printf x >", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "shell-parse-error")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "inline interpreter blocks unknown write target"
  result = shell_result("python -c \"open('x','w').write('y')\"", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "unknown-write-target")
end

with_project do |_root, project, cwd, home, install, protected_roots|
  name = "shell wrapper with script body blocks unknown write target"
  result = shell_result("sh -c 'touch generated.txt'", project: project, cwd: cwd, home: home, install: install, protected_roots: protected_roots)
  expect_result(name, result, "block", "unknown-write-target")
end

if $failures.empty?
  puts "destructive gate tests passed (#{$cases} cases)"
else
  warn $failures.join("\n")
  exit 1
end
