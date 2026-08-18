# frozen_string_literal: true

class McpOauthClient < ApplicationRecord
  belongs_to :mcp_server
  has_many :mcp_oauth_access_tokens, dependent: :destroy
  has_many :mcp_oauth_refresh_tokens, dependent: :destroy
  has_many :mcp_oauth_auth_codes, dependent: :destroy

  validates :client_id, presence: true, uniqueness: true
end
