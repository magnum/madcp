# frozen_string_literal: true

class McpOauthAccessToken < ApplicationRecord
  belongs_to :mcp_server
  belongs_to :mcp_oauth_client

  validates :token, presence: true, uniqueness: true

  scope :active, -> { where("expires_at > ?", Time.current) }

  def active?
    expires_at.future?
  end

  def schedule_refresh_job!
    minutes = mcp_server.token_refresh_in_minutes
    return unless minutes.to_i.positive?

    EmcpAuthTokenRefreshJob
      .set(wait: minutes.minutes)
      .perform_later(self, expected_expires_at: expires_at.to_i)
  end

  def refresh_for_server!
    return unless mcp_server.token_refresh_enabled?

    extend_expiry!
    schedule_refresh_job!
  end

  def extend_expiry!
    minutes = mcp_server.token_refresh_in_minutes
    update!(expires_at: McpOauthProvider.access_ttl_seconds(minutes).seconds.from_now)
    mcp_server.mcp_oauth_refresh_tokens.where(mcp_oauth_client_id: mcp_oauth_client_id).find_each do |row|
      row.update!(expires_at: McpOauthProvider.refresh_ttl_seconds(minutes).seconds.from_now)
    end
  end
end
