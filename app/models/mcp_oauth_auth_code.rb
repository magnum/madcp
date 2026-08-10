# frozen_string_literal: true

class McpOauthAuthCode < ApplicationRecord
  belongs_to :mcp_server
  belongs_to :mcp_oauth_client

  validates :code, presence: true, uniqueness: true

  def active?
    expires_at.future?
  end
end
