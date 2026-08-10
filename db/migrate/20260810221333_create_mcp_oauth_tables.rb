# frozen_string_literal: true

class CreateMcpOauthTables < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_oauth_clients do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :client_id, null: false
      t.string :client_secret
      t.string :client_name
      t.jsonb :redirect_uris, null: false, default: []
      t.string :token_endpoint_auth_method, null: false, default: "client_secret_post"
      t.jsonb :grant_types, null: false, default: []
      t.jsonb :response_types, null: false, default: []
      t.string :scope
      t.integer :client_id_issued_at, null: false
      t.integer :client_secret_expires_at, null: false, default: 0

      t.timestamps
    end
    add_index :mcp_oauth_clients, :client_id, unique: true

    create_table :mcp_oauth_access_tokens do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.references :mcp_oauth_client, null: false, foreign_key: true
      t.string :token, null: false
      t.string :scope
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :mcp_oauth_access_tokens, :token, unique: true

    create_table :mcp_oauth_refresh_tokens do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.references :mcp_oauth_client, null: false, foreign_key: true
      t.string :token, null: false
      t.string :scope
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :mcp_oauth_refresh_tokens, :token, unique: true

    create_table :mcp_oauth_auth_codes do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.references :mcp_oauth_client, null: false, foreign_key: true
      t.string :code, null: false
      t.string :redirect_uri, null: false
      t.string :code_challenge, null: false
      t.string :scope
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :mcp_oauth_auth_codes, :code, unique: true

    create_table :mcp_oauth_login_states do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :state, null: false
      t.string :client_id, null: false
      t.string :redirect_uri, null: false
      t.string :code_challenge, null: false
      t.string :client_state
      t.string :scope
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :mcp_oauth_login_states, :state, unique: true

    create_table :mcp_provider_oauth_states do |t|
      t.references :mcp_server, null: false, foreign_key: true
      t.string :state, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :expires_at, null: false

      t.timestamps
    end
    add_index :mcp_provider_oauth_states, :state, unique: true
  end
end
