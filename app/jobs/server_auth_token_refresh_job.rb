# frozen_string_literal: true

# Refreshes external provider tokens (Google, Fatture in Cloud, Twitter, Bluesky, …)
# on a schedule driven by mcp_servers.service_token_refresh_in_minutes.
class ServerAuthTokenRefreshJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(mcp_server)
    return unless mcp_server.service_token_refresh_enabled?

    mcp_server.load_credentials!
    mcp_server.refresh_service_token!
  ensure
    if mcp_server&.service_token_refresh_enabled?
      mcp_server.schedule_service_token_refresh_job!
    end
  end
end
