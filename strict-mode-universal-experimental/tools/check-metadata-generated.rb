#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "tmpdir"
require_relative "metadata_lib"

PROJECT_ROOT = StrictModeMetadata.project_root
GENERATOR = PROJECT_ROOT.join("tools/generate-metadata.rb")
MANAGED_GLOBS = %w[schemas/*.json matrices/*.json].freeze

def relative_managed_files(root)
  MANAGED_GLOBS.flat_map { |pattern| Dir[root.join(pattern)] }
               .map { |path| Pathname.new(path).relative_path_from(root).to_s }
               .sort
end

def read_managed_file(root, relative_path, errors)
  path = root.join(relative_path)
  unless path.file?
    errors << "#{relative_path}: managed metadata path is not a file"
    return nil
  end

  path.binread
rescue SystemCallError => e
  errors << "#{relative_path}: cannot read: #{e.message}"
  nil
end

def run_generator(root)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, GENERATOR.to_s, "--root", root.to_s)
  return if status.exitstatus == 0

  warn stdout unless stdout.empty?
  warn stderr unless stderr.empty?
  exit status.exitstatus || 1
end

options = { root: PROJECT_ROOT }
parser = OptionParser.new do |option_parser|
  option_parser.banner = "Usage: check-metadata-generated.rb [--root PATH]"
  option_parser.on("--root PATH", "Check generated metadata rooted at PATH") do |root|
    options[:root] = Pathname.new(root).expand_path
  end
end

begin
  parser.parse!
rescue OptionParser::ParseError => e
  warn e.message
  warn parser
  exit 2
end

root = Pathname.new(options.fetch(:root)).expand_path
spec_path = root.join("specs/17-implementation-readiness.md")
unless spec_path.exist?
  warn "#{spec_path}: missing"
  exit 1
end
unless spec_path.file?
  warn "#{spec_path}: not a file"
  exit 1
end

Dir.mktmpdir("strict-metadata-generated-") do |dir|
  generated_root = Pathname.new(dir)
  generated_root.join("specs").mkpath
  begin
    FileUtils.cp(spec_path, generated_root.join("specs/17-implementation-readiness.md"))
  rescue SystemCallError => e
    warn "#{spec_path}: cannot copy: #{e.message}"
    exit 1
  end
  run_generator(generated_root)

  expected_files = relative_managed_files(generated_root)
  actual_files = relative_managed_files(root)
  errors = []
  errors << "managed metadata file set mismatch: #{(expected_files - actual_files) + (actual_files - expected_files)}" unless expected_files == actual_files

  (expected_files & actual_files).each do |relative_path|
    expected = read_managed_file(generated_root, relative_path, errors)
    actual = read_managed_file(root, relative_path, errors)
    next if expected.nil? || actual.nil?

    errors << "#{relative_path}: generated content mismatch" unless expected == actual
  end

  if errors.empty?
    puts "metadata generation check passed"
    exit 0
  end

  errors.each { |error| warn error }
  exit 1
end
