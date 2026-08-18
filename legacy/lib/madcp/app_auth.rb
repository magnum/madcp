# frozen_string_literal: true

require "digest"
require "openssl"

module Madcp
  # App-level credentials from data/auth_tokens + data/auth_users.
  #
  #   Bearer  → auth_tokens   (TOKEN # label)
  #   Basic   → auth_users    (username:hmac_hex # label)
  #
  # Disabled lines start with "#". Files reload when mtime changes.
  class AppAuth
    Token = Data.define(:value, :label)
    User = Data.define(:username, :password_digest, :label)

    def self.hash_password(password, secret:)
      raise ArgumentError, "secret is required" if secret.to_s.empty?

      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, password.to_s)
    end

    def initialize(tokens_path:, users_path:, secret:, env_token: nil)
      @tokens_path = tokens_path
      @users_path = users_path
      @secret = secret.to_s
      @env_token = env_token.to_s
      @tokens_mtime = :unset
      @users_mtime = :unset
      @tokens = []
      @users = []
    end

    attr_reader :tokens_path, :users_path

    def configured?
      ensure_loaded!
      @tokens.any? || @users.any?
    end

    def validate!
      if @secret.empty? && file_has_active_lines?(@users_path)
        raise "MADCP_SECRET_KEY (or SECRET_KEY) is required to validate #{@users_path}"
      end
      unless configured?
        raise "no MadCP auth configured: add tokens to #{@tokens_path} " \
              "and/or users to #{@users_path} (with MADCP_SECRET_KEY)"
      end
    end

    def valid_bearer?(token)
      !lookup_bearer(token).nil?
    end

    def lookup_bearer(token)
      candidate = token.to_s
      return nil if candidate.empty?

      ensure_loaded!
      @tokens.find { |entry| secure_equals(entry.value, candidate) }
    end

    def valid_basic?(username, password)
      return false if @secret.empty?

      entry = lookup_user(username)
      return false unless entry

      digest = self.class.hash_password(password, secret: @secret)
      secure_equals(entry.password_digest, digest)
    end

    private

    def lookup_user(username)
      candidate = username.to_s
      return nil if candidate.empty?

      ensure_loaded!
      @users.find { |entry| secure_equals(entry.username, candidate) }
    end

    def ensure_loaded!
      tokens_mtime = file_mtime(@tokens_path)
      users_mtime = file_mtime(@users_path)
      return if @tokens_mtime == tokens_mtime && @users_mtime == users_mtime

      @tokens = load_tokens
      @users = load_users
      @tokens_mtime = tokens_mtime
      @users_mtime = users_mtime
    end

    def load_tokens
      tokens = []
      tokens << Token.new(value: @env_token, label: "MADCP_AUTH_TOKEN") unless @env_token.empty?

      each_active_line(@tokens_path) do |body, label|
        next if tokens.any? { |t| secure_equals(t.value, body) }

        tokens << Token.new(value: body, label: label)
      end
      tokens
    end

    def load_users
      users = []
      each_active_line(@users_path) do |body, label|
        username, colon, digest = body.partition(":")
        username = username.strip
        digest = digest.strip.downcase
        next if username.empty? || colon.empty? || !digest.match?(/\A[0-9a-f]{64}\z/)
        next if users.any? { |u| secure_equals(u.username, username) }

        users << User.new(username: username, password_digest: digest, label: label)
      end
      users
    end

    def each_active_line(path)
      return unless File.file?(path)

      File.readlines(path, chomp: true).each do |line|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        body, separator, label = stripped.partition(/\s*#\s*/)
        body = body.strip
        next if body.empty?

        label = separator.empty? || label.strip.empty? ? "unnamed" : label.strip
        yield body, label
      end
    end

    def file_has_active_lines?(path)
      each_active_line(path) { return true }
      false
    end

    def file_mtime(path)
      File.file?(path) ? File.mtime(path) : nil
    rescue Errno::ENOENT
      nil
    end

    def secure_equals(a, b)
      Madcp.secure_equals(a, b)
    end
  end
end
