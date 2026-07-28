# frozen_string_literal: true

require "digest"
require "openssl"

module Madcp
  # Line-oriented MadCP app tokens (operator UI + static MCP bearer).
  #
  # Format (one token per line):
  #   tok_live_abc123 # claude-desktop
  #   tok_live_def456 # cowork
  #   # tok_old_revoked # disabled by leading #
  #
  # Blank lines and lines whose first non-space character is "#" are ignored.
  class AuthTokenStore
    Entry = Data.define(:token, :label)

    def initialize(path:, extra_tokens: [])
      @path = path
      @extra_tokens = Array(extra_tokens).map do |item|
        case item
        when Entry then item
        when Array then Entry.new(token: item[1].to_s, label: item[0].to_s)
        when Hash then Entry.new(token: item[:token].to_s, label: item[:label].to_s)
        else Entry.new(token: item.to_s, label: "env")
        end
      end.reject { |entry| entry.token.empty? }
      @mtime = :unset
      @entries = []
      reload!
    end

    def path = @path

    def any?
      reload_if_stale!
      !@entries.empty?
    end

    def valid?(token)
      !lookup(token).nil?
    end

    def lookup(token)
      candidate = token.to_s
      return nil if candidate.empty?

      reload_if_stale!
      @entries.find { |entry| secure_equals(entry.token, candidate) }
    end

    def reload!
      @entries = load_entries
      @mtime = current_mtime
      @entries
    end

    private

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
      entries = @extra_tokens.dup
      return entries unless File.file?(@path)

      File.readlines(@path, chomp: true).each do |line|
        entry = parse_line(line)
        next unless entry
        next if entries.any? { |existing| secure_equals(existing.token, entry.token) }

        entries << entry
      end
      entries
    end

    def parse_line(line)
      stripped = line.to_s.strip
      return nil if stripped.empty?
      # Disabled / comment line (including "# token # name").
      return nil if stripped.start_with?("#")

      token, separator, label = stripped.partition(/\s*#\s*/)
      token = token.strip
      return nil if token.empty?

      label = separator.empty? ? "unnamed" : label.strip
      label = "unnamed" if label.empty?
      Entry.new(token: token, label: label)
    end

    def secure_equals(a, b)
      OpenSSL.fixed_length_secure_compare(
        Digest::SHA256.digest(a.to_s),
        Digest::SHA256.digest(b.to_s),
      )
    end
  end
end
