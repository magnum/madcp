# frozen_string_literal: true

require "digest"
require "openssl"
require "json"

# Reopen the Rails application module (Emcp) with host helpers.
# Do not define lib/emcp.rb — Zeitwerk will not load it once Emcp exists.
module Emcp
  VERSION = "0.1.0" unless const_defined?(:VERSION)

  ToolDefinition = Data.define(:name, :description, :input_schema, :write, :handler) unless const_defined?(:ToolDefinition)
  ResourceDefinition = Data.define(:uri, :name, :description, :mime_type, :handler) unless const_defined?(:ResourceDefinition)

  module_function

  def sanitize_env_value(value)
    cleaned = value.to_s
    hash_at = cleaned.index("#")
    cleaned = cleaned[0...hash_at] if hash_at
    cleaned.strip
  end

  def secure_equals(a, b)
    OpenSSL.fixed_length_secure_compare(
      Digest::SHA256.digest(a.to_s),
      Digest::SHA256.digest(b.to_s),
    )
  end

  def public_url
    ENV.fetch("EMCP_PUBLIC_URL") { ENV.fetch("APP_HOST", "http://localhost:3000") }.to_s.sub(%r{/\z}, "")
  end

  def apply_env_sanitization!
    ENV.each_key do |key|
      original = ENV[key]
      next if original.nil?

      cleaned = sanitize_env_value(original)
      next if cleaned == original

      if cleaned.empty?
        ENV.delete(key)
      else
        ENV[key] = cleaned
      end
    end
  end

  def register_integration(klass)
    McpServer.register_integration(klass)
  end
end

Emcp.apply_env_sanitization!

# to_prepare re-runs after each code reload in development so STI subclasses
# under servers/ are rebound to the current McpServer class.
Rails.application.config.to_prepare do
  next unless ActiveRecord::Base.connection.data_source_exists?("mcp_servers")

  McpServer.discover!
rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
  # db:create / first boot / sqlite not ready yet
end
