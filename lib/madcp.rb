# frozen_string_literal: true

require_relative "madcp/auth_token_store"
require_relative "madcp/auth_user_store"
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

  # Trim whitespace and strip shell/dotenv-style comments: everything from the
  # first "#" onward (including "#"), so values like "id # required" or
  # "# optional" from .env.example do not leak into credentials.
  def self.sanitize_env_value(value)
    cleaned = value.to_s
    hash_at = cleaned.index("#")
    cleaned = cleaned[0...hash_at] if hash_at
    cleaned.strip
  end

  # Rewrite ENV in place so every reader (not only sanitize_env_value call sites)
  # sees comment-stripped values loaded from .env / the process environment.
  def self.apply_env_sanitization!
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
end
