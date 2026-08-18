# frozen_string_literal: true

class AddServiceTokenRefreshInMinutesToMcpServers < ActiveRecord::Migration[8.1]
  DEFAULTS = {
    "googleworkspace" => 1_440,   # daily — keeps refresh token warm (avoids 6‑month idle expiry; helps Testing apps)
    "fattureincloud" => 1_320,  # ~22h — access tokens last ~24h
    "twitter" => 90,              # access tokens ~2h
    "bluesky" => 90,              # access JWTs are short-lived
  }.freeze

  def up
    add_column :mcp_servers, :service_token_refresh_in_minutes, :integer

    DEFAULTS.each do |code, minutes|
      execute <<-SQL.squish
        UPDATE mcp_servers
        SET service_token_refresh_in_minutes = #{minutes}
        WHERE code = #{connection.quote(code)}
      SQL
    end
  end

  def down
    remove_column :mcp_servers, :service_token_refresh_in_minutes
  end
end
