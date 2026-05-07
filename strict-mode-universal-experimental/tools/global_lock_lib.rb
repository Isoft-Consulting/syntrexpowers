# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"
require_relative "metadata_lib"

class StrictModeGlobalLock
  SHA256_PATTERN = /\A[0-9a-f]{64}\z/.freeze

  class DuplicateKeyHash < Hash
    def []=(key, value)
      raise "duplicate JSON object key: #{key}" if key?(key)

      super
    end
  end

  OWNER_FIELDS = %w[
    schema_version
    lock_scope
    provider
    session_key
    raw_session_hash
    cwd
    project_dir
    transaction_kind
    pid
    process_start
    created_at
    timeout_at
    owner_hash
  ].freeze

  TRANSACTION_KINDS = %w[
    install
    rollback
    uninstall
    cleanup
    repair
    prompt-event
    pre-tool-intent
    permission-decision
    post-tool-record
    dirty-baseline
    protected-baseline
    fdr-import
    fdr-cycle
    approval-block
    approval-consume
    optout-approval
    nested-token
    worker-context-pack
    worker-invocation
    worker-result
  ].freeze

  attr_reader :path

  def self.load_owner(path, expected_scope: nil)
    path = Pathname.new(path)
    return { "trusted" => false, "owner" => nil, "errors" => ["#{path}: owner missing"], "stale_candidate" => false } unless path.file?
    return { "trusted" => false, "owner" => nil, "errors" => ["#{path}: owner must not be a symlink"], "stale_candidate" => false } if path.symlink?

    owner = JSON.parse(path.read, object_class: DuplicateKeyHash)
    errors = validate_owner(owner, expected_scope: expected_scope)
    {
      "trusted" => errors.empty?,
      "owner" => owner,
      "errors" => errors,
      "stale_candidate" => errors.empty? && stale_candidate?(owner)
    }
  rescue JSON::ParserError, RuntimeError => e
    { "trusted" => false, "owner" => nil, "errors" => ["#{path}: malformed owner JSON: #{e.message}"], "stale_candidate" => false }
  end

  def self.validate_owner(owner, expected_scope: nil)
    return ["lock owner must be a JSON object"] unless owner.is_a?(Hash)

    errors = []
    actual = owner.keys.sort
    expected = OWNER_FIELDS.sort
    if actual != expected
      missing = expected - actual
      extra = actual - expected
      errors << "lock owner fields mismatch#{field_mismatch_details(missing, extra)}"
      return errors
    end

    errors << "schema_version must be 1" unless owner.fetch("schema_version") == 1
    scope = owner.fetch("lock_scope")
    errors << "lock_scope must be global or session" unless %w[global session].include?(scope)
    errors << "lock_scope must be #{expected_scope}" if expected_scope && scope != expected_scope
    %w[provider session_key raw_session_hash cwd project_dir transaction_kind process_start created_at timeout_at owner_hash].each do |field|
      errors << "#{field} must be a string" unless owner.fetch(field).is_a?(String)
    end
    errors << "transaction_kind invalid" unless TRANSACTION_KINDS.include?(owner.fetch("transaction_kind"))
    errors << "pid must be a non-negative integer" unless owner.fetch("pid").is_a?(Integer) && owner.fetch("pid") >= 0
    tuple_fields = %w[provider session_key raw_session_hash cwd project_dir]
    if %w[global session].include?(scope) && tuple_fields.all? { |field| owner.fetch(field).is_a?(String) }
      errors.concat(validate_owner_tuple(owner, scope))
    end
    created_at = parse_owner_time(owner.fetch("created_at"), "created_at", errors)
    timeout_at = parse_owner_time(owner.fetch("timeout_at"), "timeout_at", errors)
    errors << "timeout_at must not be earlier than created_at" if created_at && timeout_at && timeout_at < created_at
    owner_hash = owner.fetch("owner_hash")
    errors << "owner_hash must be lowercase SHA-256" unless owner_hash.is_a?(String) && owner_hash.match?(SHA256_PATTERN)
    errors << "owner_hash mismatch" if owner_hash.is_a?(String) && owner_hash.match?(SHA256_PATTERN) &&
      StrictModeMetadata.hash_record(owner, "owner_hash") != owner_hash
    errors
  end

  def self.stale_candidate?(owner, now: Time.now.utc)
    return false unless validate_owner(owner).empty?

    Time.iso8601(owner.fetch("timeout_at")) <= now
  rescue ArgumentError
    false
  end

  def self.acquire!(install_root, state_root:, transaction_kind:, timeout_seconds: 3600)
    raise "transaction_kind must be supported" unless TRANSACTION_KINDS.include?(transaction_kind)

    lock_path = Pathname.new(install_root).join("state-global.lock")
    lock_path.dirname.mkpath
    begin
      Dir.mkdir(lock_path.to_s, 0o700)
    rescue Errno::EEXIST
      raise "#{lock_path}: another global transaction is active"
    rescue SystemCallError => e
      raise e.message
    end

    lock = new(lock_path)
    begin
      lock.write_owner!(transaction_kind, timeout_seconds)
      lock
    rescue SystemCallError => e
      lock.release
      raise e.message
    rescue RuntimeError
      lock.release
      raise
    end
  end

  def initialize(path)
    @path = Pathname.new(path)
    @released = false
  end

  def release
    return if @released

    owner_path = path.join("owner.json")
    FileUtils.rm_f(owner_path) if owner_path.file? && !owner_path.symlink?
    Dir.rmdir(path.to_s) if lock_directory?
  rescue Errno::ENOENT
    nil
  ensure
    @released = true
  end

  def write_owner!(transaction_kind, timeout_seconds)
    created = Time.now.utc
    owner = {
      "schema_version" => 1,
      "lock_scope" => "global",
      "provider" => "",
      "session_key" => "",
      "raw_session_hash" => "",
      "cwd" => "",
      "project_dir" => "",
      "transaction_kind" => transaction_kind,
      "pid" => Process.pid,
      "process_start" => "",
      "created_at" => created.iso8601,
      "timeout_at" => (created + timeout_seconds).iso8601,
      "owner_hash" => ""
    }
    owner["owner_hash"] = StrictModeMetadata.hash_record(owner, "owner_hash")
    errors = self.class.validate_owner(owner, expected_scope: "global")
    raise "global lock owner invalid: #{errors.join("; ")}" unless errors.empty?

    owner_path = path.join("owner.json")
    tmp = path.join(".owner.json.tmp-#{$$}-#{SecureRandom.hex(4)}")
    tmp.write(JSON.pretty_generate(owner) + "\n")
    File.chmod(0o600, tmp)
    File.rename(tmp, owner_path)
  end

  private

  def lock_directory?
    File.lstat(path.to_s).directory?
  rescue Errno::ENOENT
    false
  end

  def self.field_mismatch_details(missing, extra)
    details = []
    details << " (missing #{missing.join(", ")})" unless missing.empty?
    details << " (extra #{extra.join(", ")})" unless extra.empty?
    details.join
  end

  def self.validate_owner_tuple(owner, scope)
    tuple_fields = %w[provider session_key raw_session_hash cwd project_dir]
    case scope
    when "global"
      tuple_fields.select { |field| owner.fetch(field) != "" }.map { |field| "#{field} must be empty for global lock" }
    when "session"
      tuple_fields.select { |field| owner.fetch(field).empty? }.map { |field| "#{field} must be non-empty for session lock" }
    else
      []
    end
  end

  def self.parse_owner_time(value, field, errors)
    unless value.is_a?(String) && !value.empty?
      errors << "#{field} must be a non-empty ISO-8601 string"
      return nil
    end
    Time.iso8601(value)
  rescue ArgumentError
    errors << "#{field} must parse as ISO-8601"
    nil
  end
end
