# frozen_string_literal: true

# Extends MadCP-issued MCP client OAuth access/refresh TTLs when
# mcp_servers.token_refresh_in_minutes is set. Does not touch provider tokens.
class MadcpAuthTokenRefreshJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(access_token, expected_expires_at:)
    return if access_token.expires_at.to_i != expected_expires_at.to_i

    access_token.refresh_for_server!
  end
end
