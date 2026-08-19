# frozen_string_literal: true

module Emcp
  class Config
    attr_reader :root, :host, :port, :public_url, :allowed_hosts, :allowed_origins,
                :app_auth, :allow_write_methods, :request_log_path, :request_log_max_chars

    def initialize(root:)
      @root = root
      @host = ENV.fetch("EMCP_HOST", "0.0.0.0")
      @port = ENV.fetch("EMCP_PORT", "8765").to_i
      @public_url = ENV.fetch("EMCP_PUBLIC_URL", "").sub(%r{/+\z}, "")
      @app_auth = AppAuth.new(
        tokens_path: ENV.fetch("EMCP_AUTH_TOKENS_PATH", File.join(@root, "data", "auth_tokens")),
        users_path: ENV.fetch("EMCP_AUTH_USERS_PATH", File.join(@root, "data", "auth_users")),
        secret: Emcp.sanitize_env_value(ENV.fetch("EMCP_SECRET_KEY", ENV.fetch("SECRET_KEY", ""))),
        env_token: Emcp.sanitize_env_value(ENV.fetch("EMCP_AUTH_TOKEN", "")),
      )
      global_write = ENV.fetch(
        "EMCP_ALLOW_WRITE",
        ENV.fetch("EMCP_ALLOW_WRITE_METHODS", "false"),
      )
      @allow_write_methods = truthy?(global_write)
      @allowed_hosts = csv(ENV.fetch("EMCP_ALLOWED_HOSTS", "localhost,127.0.0.1"))
      @allowed_origins = csv(ENV.fetch("EMCP_ALLOWED_ORIGINS", ""))
      @allowed_origins = derived_origins if @allowed_origins.empty?
      @allowed_origins << @public_url unless @public_url.empty?
      @allowed_origins.uniq!
      @request_log_path = ENV.fetch(
        "EMCP_REQUEST_LOG",
        File.join(@root, "logs", "requests.logs"),
      )
      @request_log_max_chars = ENV.fetch("EMCP_REQUEST_LOG_MAX_CHARS", "8000").to_i
    end

    def validate!
      raise "EMCP_PUBLIC_URL is required" if @public_url.empty?

      @app_auth.validate!
    end

    def data_dir(server_id)
      File.join(@root, "data", server_id)
    end

    def write_allowed_for?(server_id)
      prefix = server_id.upcase.gsub(/[^A-Z0-9]/, "_")
      raw = ENV["#{prefix}_ALLOW_WRITE"]
      raw = ENV["EMCP_#{prefix}_ALLOW_WRITE_METHODS"] if raw.nil?
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
