# frozen_string_literal: true

require "digest"
require "openssl"

module Madcp
  # Line-oriented MadCP operator users (HTTP Basic Auth for the UI).
  #
  # Format (one user per line):
  #   username:hmac_sha256_hex # label
  #   # disabled:hmac_sha256_hex # old
  #
  # Password digests are HMAC-SHA256(MADCP_SECRET_KEY, password) as lowercase hex.
  # Blank lines and lines whose first non-space character is "#" are ignored.
  class AuthUserStore
    Entry = Data.define(:username, :password_digest, :label)

    def self.hash_password(password, secret:)
      raise ArgumentError, "secret is required" if secret.to_s.empty?

      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, password.to_s)
    end

    def initialize(path:, secret:, extra_users: [])
      @path = path
      @secret = secret.to_s
      @extra_users = Array(extra_users).map { |item| coerce_entry(item) }.compact
      @mtime = :unset
      @entries = []
      reload!
    end

    def path = @path

    def any?
      reload_if_stale!
      !@entries.empty?
    end

    def valid?(username, password)
      return false if @secret.empty?

      entry = lookup(username)
      return false unless entry

      digest = self.class.hash_password(password, secret: @secret)
      secure_equals(entry.password_digest, digest)
    end

    def lookup(username)
      candidate = username.to_s
      return nil if candidate.empty?

      reload_if_stale!
      @entries.find { |entry| secure_equals(entry.username, candidate) }
    end

    def reload!
      @entries = load_entries
      @mtime = current_mtime
      @entries
    end

    private

    def coerce_entry(item)
      case item
      when Entry
        item if !item.username.empty? && !item.password_digest.empty?
      when Hash
        Entry.new(
          username: item[:username].to_s,
          password_digest: item[:password_digest].to_s,
          label: item.fetch(:label, "env").to_s,
        ).then { |e| e.username.empty? || e.password_digest.empty? ? nil : e }
      else
        nil
      end
    end

    def reload_if_stale!
      mtime = current_mtime
      return if @mtime == mtime

      reload!
    end

    def current_mtime
      File.file?(@path) ? File.mtime(@path) : nil
    rescue Errno::ENOENT
      nil
    end

    def load_entries
      entries = @extra_users.dup
      return entries unless File.file?(@path)

      File.readlines(@path, chomp: true).each do |line|
        entry = parse_line(line)
        next unless entry
        next if entries.any? { |existing| secure_equals(existing.username, entry.username) }

        entries << entry
      end
      entries
    end

    def parse_line(line)
      stripped = line.to_s.strip
      return nil if stripped.empty?
      return nil if stripped.start_with?("#")

      account, separator, label = stripped.partition(/\s*#\s*/)
      username, colon, digest = account.partition(":")
      username = username.strip
      digest = digest.strip.downcase
      return nil if username.empty? || colon.empty? || digest.empty?
      return nil unless digest.match?(/\A[0-9a-f]{64}\z/)

      label = separator.empty? ? "unnamed" : label.strip
      label = "unnamed" if label.empty?
      Entry.new(username: username, password_digest: digest, label: label)
    end

    def secure_equals(a, b)
      OpenSSL.fixed_length_secure_compare(
        Digest::SHA256.digest(a.to_s),
        Digest::SHA256.digest(b.to_s),
      )
    end
  end
end
