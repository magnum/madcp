# frozen_string_literal: true

class SetBasecampServiceTokenRefreshDefault < ActiveRecord::Migration[8.1]
  # Basecamp CLI access tokens last ~2 weeks; weekly refresh keeps credentials.json warm.
  def up
    execute <<-SQL.squish
      UPDATE mcp_servers
      SET service_token_refresh_in_minutes = 10080
      WHERE code = 'basecamp'
        AND (service_token_refresh_in_minutes IS NULL OR service_token_refresh_in_minutes = 0)
    SQL
  end

  def down
    execute <<-SQL.squish
      UPDATE mcp_servers
      SET service_token_refresh_in_minutes = NULL
      WHERE code = 'basecamp'
        AND service_token_refresh_in_minutes = 10080
    SQL
  end
end
