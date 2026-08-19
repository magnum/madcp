# frozen_string_literal: true

class RenameMadcpStiTypesToEmcp < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE mcp_servers
      SET type = REPLACE(type, 'Madcp::', 'Emcp::')
      WHERE type LIKE 'Madcp::%'
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE mcp_servers
      SET type = REPLACE(type, 'Emcp::', 'Madcp::')
      WHERE type LIKE 'Emcp::%'
    SQL
  end
end
