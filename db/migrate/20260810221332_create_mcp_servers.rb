# frozen_string_literal: true

class CreateMcpServers < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_servers do |t|
      t.string :code, null: false
      t.string :type, null: false
      t.string :name, null: false
      t.text :description, null: false, default: ""
      t.string :version, null: false, default: "0.1.0"
      t.boolean :allow_write, null: false, default: false
      t.text :credentials
      t.text :oauth_token_payload
      t.boolean :oauth_token_retrieval, null: false, default: false

      t.timestamps
    end

    add_index :mcp_servers, :code, unique: true
    add_index :mcp_servers, :type
  end
end
