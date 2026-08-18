# frozen_string_literal: true

class McpProviderOauthState < ApplicationRecord
  belongs_to :mcp_server

  validates :state, presence: true, uniqueness: true

  def active?
    expires_at.future?
  end
end
