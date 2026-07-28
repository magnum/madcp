# frozen_string_literal: true

module Madcp
  class Config
    attr_reader :root, :host, :port, :public_url, :allowed_hosts, :allowed_origins,
                :auth_token_store, :auth_tokens_path, :allow_write_methods,
                :request_log_path, :request_log_max_chars

    def initialize(root:)
      @root = root
      @host = ENV.fetch("MADCP_HOST", "0.0.0.0")
      @port = ENV.fetch("MADCP_PORT", "8765").to_i
      @public_url = ENV.fetch("MADCP_PUBLIC_URL", "").sub(%r{/+\z}, "")
      @auth_tokens_path = ENV.fetch(
        "MADCP_AUTH_TOKENS_PATH",
        File.join(@root, "data", "auth_tokens"),
      )
      env_token = Madcp.sanitize_env_value(ENV.fetch("MADCP_AUTH_TOKEN", ""))
      extra = env_token.empty? ? [] : [AuthTokenStore::Entry.new(token: env_token, label: "MADCP_AUTH_TOKEN")]
      @auth_token_store = AuthTokenStore.new(path: @auth_tokens_path, extra_tokens: extra)
      global_write = ENV.fetch(
        "MADCP_ALLOW_WRITE",
        ENV.fetch("MADCP_ALLOW_WRITE_METHODS", "false"),
      )
      @allow_write_methods = truthy?(global_write)
      @allowed_hosts = csv(ENV.fetch("MADCP_ALLOWED_HOSTS", "localhost,127.0.0.1"))
      @allowed_origins = csv(ENV.fetch("MADCP_ALLOWED_ORIGINS", ""))
      @allowed_origins = derived_origins if @allowed_origins.empty?
      @allowed_origins << @public_url unless @public_url.empty?
      @allowed_origins.uniq!
      @request_log_path = ENV.fetch(
        "MADCP_REQUEST_LOG",
        File.join(@root, "logs", "requests.logs"),
      )
      @request_log_max_chars = ENV.fetch("MADCP_REQUEST_LOG_MAX_CHARS", "8000").to_i
    end

    def validate!
      raise "MADCP_PUBLIC_URL is required" if @public_url.empty?
      return if @auth_token_store.any?

      raise "no MadCP auth tokens configured: add lines to #{@auth_tokens_path} " \
            "(token # label) or set MADCP_AUTH_TOKEN"
    end

    def data_dir(server_id)
      File.join(@root, "data", server_id)
    end

    def write_allowed_for?(server_id)
      prefix = server_id.upcase.gsub(/[^A-Z0-9]/, "_")
      raw = ENV["#{prefix}_ALLOW_WRITE"]
      raw = ENV["MADCP_#{prefix}_ALLOW_WRITE_METHODS"] if raw.nil?
      raw.nil? ? @allow_write_methods : truthy?(raw)
    end

    private

    def csv(value)
      value.split(",").map(&:strip).reject(&:empty?)
    end

    def truthy?(value)
      %w[1 true yes on].include?(value.to_s.downcase)
    end

    def derived_origins
      @allowed_hosts.flat_map do |host|
        bare = host.start_with?("[") ? host : host.split(":").first
        ["https://#{bare}", "http://#{bare}"]
      end
    end
  end
end
