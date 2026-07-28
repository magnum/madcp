# frozen_string_literal: true

require_relative "madcp/config"
require_relative "madcp/cli_client"
require_relative "madcp/integration"
require_relative "madcp/registry"
require_relative "madcp/renderer"
require_relative "madcp/oauth_provider"
require_relative "madcp/oauth_retrieval_store"
require_relative "madcp/request_logger"
require_relative "madcp/app"

module Madcp
  VERSION = "0.1.0"

  # Trim whitespace and drop placeholder values copied from .env.example
  # (for example "# optional" / "#optional").
  def self.sanitize_env_value(value)
    cleaned = value.to_s.strip
    return "" if cleaned.empty?
    return "" if cleaned.match?(/\A#\s*optional\z/i)

    cleaned = cleaned.sub(/\s+#\s*optional\z/i, "").strip
    return "" if cleaned.match?(/\A#\s*optional\z/i)

    cleaned
  end
end
