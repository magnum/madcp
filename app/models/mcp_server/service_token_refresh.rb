# frozen_string_literal: true

# Proactive refresh of *provider* credentials (Google, Fatture, Twitter, Bluesky, …).
# Distinct from MadcpAuthTokenRefreshJob, which only extends MadCP-issued MCP client OAuth TTLs.
module McpServer::ServiceTokenRefresh
  extend ActiveSupport::Concern

  class_methods do
    def default_service_token_refresh_in_minutes
      nil
    end
  end

  def service_token_refresh_enabled?
    service_token_refresh_in_minutes.to_i.positive?
  end

  def schedule_service_token_refresh_job!
    return unless service_token_refresh_enabled?

    ServerAuthTokenRefreshJob
      .set(wait: service_token_refresh_in_minutes.minutes)
      .perform_later(self)
  end

  # Override in integrations that can renew provider tokens without operator re-auth.
  # Return true when credentials were updated.
  def refresh_service_token!
    false
  end
end
