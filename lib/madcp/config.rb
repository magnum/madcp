# frozen_string_literal: true

module Madcp
  class Config
    attr_reader :root, :host, :port, :public_url, :allowed_hosts, :allowed_origins,
                :auth_username, :auth_password, :static_bearer, :allow_write_methods

    def initialize(root:)
      @root = root
      @host = ENV.fetch("MADCP_HOST", "0.0.0.0")
      @port = ENV.fetch("MADCP_PORT", "8765").to_i
      @public_url = ENV.fetch("MADCP_PUBLIC_URL", "").sub(%r{/+\z}, "")
      @static_bearer = Madcp.sanitize_env_value(ENV.fetch("MADCP_AUTH_TOKEN", ""))
      @auth_username = Madcp.sanitize_env_value(
        ENV.fetch("MADCP_AUTH_USERNAME") do
          ENV.fetch("MADCP_OAUTH_USERNAME", "admin")
        end,
      )
      @auth_username = "admin" if @auth_username.empty?
      @auth_password = Madcp.sanitize_env_value(
        ENV.fetch("MADCP_AUTH_PASSWORD") do
          ENV.fetch("MADCP_OAUTH_PASSWORD", "")
        end,
      )
      @auth_password = @static_bearer if @auth_password.empty?
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
    end

    def validate!
      raise "MADCP_PUBLIC_URL is required" if @public_url.empty?
      raise "MADCP_AUTH_PASSWORD or MADCP_AUTH_TOKEN is required" if @auth_password.empty?
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
