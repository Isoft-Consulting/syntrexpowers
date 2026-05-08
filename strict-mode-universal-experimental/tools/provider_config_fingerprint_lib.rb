# frozen_string_literal: true

require "digest"
require "pathname"

module StrictModeProviderConfigFingerprint
  extend self

  ZERO_HASH = "0" * 64

  def content_sha256(path, kind, provider)
    return ZERO_HASH unless path.file?

    if mutable_provider_state_record?(path.to_s, kind, provider)
      return Digest::SHA256.hexdigest(strip_codex_mutable_state_tables(path.read))
    end

    Digest::SHA256.file(path).hexdigest
  end

  def mutable_provider_state_record?(path, kind, provider)
    provider == "codex" &&
      kind == "provider-config" &&
      Pathname.new(path).basename.to_s == "config.toml" &&
      Pathname.new(path).dirname.basename.to_s == ".codex"
  rescue ArgumentError
    false
  end

  def strip_codex_mutable_state_tables(text)
    output = []
    skip = false
    text.lines.each do |line|
      if (match = line.match(/\A\s*\[([^\]]+)\]\s*(?:#.*)?\z/))
        table = match[1]
        skip = table == "hooks.state" || table.start_with?("hooks.state.")
        output.pop while skip && output.last&.strip == ""
      end
      output << line unless skip
    end
    normalized = output.join.rstrip
    normalized.empty? ? "" : "#{normalized}\n"
  end
end
