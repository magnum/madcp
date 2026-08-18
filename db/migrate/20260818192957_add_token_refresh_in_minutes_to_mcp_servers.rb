# frozen_string_literal: true

class AddTokenRefreshInMinutesToMcpServers < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_servers, :token_refresh_in_minutes, :integer
  end
end
