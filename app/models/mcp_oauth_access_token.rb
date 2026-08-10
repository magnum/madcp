# frozen_string_literal: true

class McpOauthAccessToken < ApplicationRecord
  belongs_to :mcp_server
  belongs_to :mcp_oauth_client

  validates :token, presence: true, uniqueness: true

  scope :active, -> { where("expires_at > ?", Time.current) }

  def active?
    expires_at.future?
  end
end
