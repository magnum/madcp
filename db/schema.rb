# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_18_235500) do
  create_table "api_keys", force: :cascade do |t|
    t.bigint "bearer_id", null: false
    t.string "bearer_type", null: false
    t.string "common_token_prefix", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "random_token_prefix", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["bearer_type", "bearer_id"], name: "index_api_keys_on_bearer"
    t.index ["token_digest"], name: "index_api_keys_on_token_digest", unique: true
  end

  create_table "invitations", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.string "signature", null: false
    t.string "state", default: "created", null: false
    t.datetime "updated_at", null: false
    t.datetime "valid_from", null: false
    t.datetime "valid_to", null: false
    t.index ["code"], name: "index_invitations_on_code", unique: true
    t.index ["signature"], name: "index_invitations_on_signature", unique: true
    t.index ["state"], name: "index_invitations_on_state"
  end

  create_table "mcp_oauth_access_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_oauth_client_id", null: false
    t.bigint "mcp_server_id", null: false
    t.string "scope"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_oauth_client_id"], name: "index_mcp_oauth_access_tokens_on_mcp_oauth_client_id"
    t.index ["mcp_server_id"], name: "index_mcp_oauth_access_tokens_on_mcp_server_id"
    t.index ["token"], name: "index_mcp_oauth_access_tokens_on_token", unique: true
  end

  create_table "mcp_oauth_auth_codes", force: :cascade do |t|
    t.string "code", null: false
    t.string "code_challenge", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_oauth_client_id", null: false
    t.bigint "mcp_server_id", null: false
    t.string "redirect_uri", null: false
    t.string "scope"
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_mcp_oauth_auth_codes_on_code", unique: true
    t.index ["mcp_oauth_client_id"], name: "index_mcp_oauth_auth_codes_on_mcp_oauth_client_id"
    t.index ["mcp_server_id"], name: "index_mcp_oauth_auth_codes_on_mcp_server_id"
  end

  create_table "mcp_oauth_clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.integer "client_id_issued_at", null: false
    t.string "client_name"
    t.string "client_secret"
    t.integer "client_secret_expires_at", default: 0, null: false
    t.datetime "created_at", null: false
    t.json "grant_types", default: [], null: false
    t.bigint "mcp_server_id", null: false
    t.json "redirect_uris", default: [], null: false
    t.json "response_types", default: [], null: false
    t.string "scope"
    t.string "token_endpoint_auth_method", default: "client_secret_post", null: false
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_mcp_oauth_clients_on_client_id", unique: true
    t.index ["mcp_server_id"], name: "index_mcp_oauth_clients_on_mcp_server_id"
  end

  create_table "mcp_oauth_login_states", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_state"
    t.string "code_challenge", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_server_id", null: false
    t.string "redirect_uri", null: false
    t.string "scope"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_server_id"], name: "index_mcp_oauth_login_states_on_mcp_server_id"
    t.index ["state"], name: "index_mcp_oauth_login_states_on_state", unique: true
  end

  create_table "mcp_oauth_refresh_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_oauth_client_id", null: false
    t.bigint "mcp_server_id", null: false
    t.string "scope"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_oauth_client_id"], name: "index_mcp_oauth_refresh_tokens_on_mcp_oauth_client_id"
    t.index ["mcp_server_id"], name: "index_mcp_oauth_refresh_tokens_on_mcp_server_id"
    t.index ["token"], name: "index_mcp_oauth_refresh_tokens_on_token", unique: true
  end

  create_table "mcp_provider_oauth_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "mcp_server_id", null: false
    t.json "payload", default: {}, null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["mcp_server_id"], name: "index_mcp_provider_oauth_states_on_mcp_server_id"
    t.index ["state"], name: "index_mcp_provider_oauth_states_on_state", unique: true
  end

  create_table "mcp_servers", force: :cascade do |t|
    t.boolean "allow_write", default: false, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "credentials"
    t.text "description", default: "", null: false
    t.string "name", null: false
    t.text "oauth_token_payload"
    t.boolean "oauth_token_retrieval", default: false, null: false
    t.integer "service_token_refresh_in_minutes"
    t.integer "token_refresh_in_minutes"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.string "version", default: "0.1.0", null: false
    t.index ["code"], name: "index_mcp_servers_on_code", unique: true
    t.index ["type"], name: "index_mcp_servers_on_type"
  end

  create_table "plan_types", force: :cascade do |t|
    t.string "code"
    t.datetime "created_at", null: false
    t.integer "days"
    t.text "description"
    t.boolean "is_active"
    t.boolean "is_default"
    t.string "name"
    t.decimal "price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_plan_types_on_code", unique: true
  end

  create_table "plans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "plan_type_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.date "valid_from"
    t.date "valid_to"
    t.index ["plan_type_id"], name: "index_plans_on_plan_type_id"
    t.index ["user_id"], name: "index_plans_on_user_id"
  end

  create_table "roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.bigint "resource_id"
    t.string "resource_type"
    t.datetime "updated_at", null: false
    t.index ["name", "resource_type", "resource_id"], name: "index_roles_on_name_and_resource_type_and_resource_id"
    t.index ["resource_type", "resource_id"], name: "index_roles_on_resource"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "firstname"
    t.string "lastname"
    t.string "password_digest"
    t.string "provider"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid", unique: true, where: "provider IS NOT NULL AND uid IS NOT NULL"
  end

  create_table "users_roles", id: false, force: :cascade do |t|
    t.bigint "role_id"
    t.bigint "user_id"
    t.index ["role_id"], name: "index_users_roles_on_role_id"
    t.index ["user_id", "role_id"], name: "index_users_roles_on_user_id_and_role_id"
    t.index ["user_id"], name: "index_users_roles_on_user_id"
  end

  add_foreign_key "mcp_oauth_access_tokens", "mcp_oauth_clients"
  add_foreign_key "mcp_oauth_access_tokens", "mcp_servers"
  add_foreign_key "mcp_oauth_auth_codes", "mcp_oauth_clients"
  add_foreign_key "mcp_oauth_auth_codes", "mcp_servers"
  add_foreign_key "mcp_oauth_clients", "mcp_servers"
  add_foreign_key "mcp_oauth_login_states", "mcp_servers"
  add_foreign_key "mcp_oauth_refresh_tokens", "mcp_oauth_clients"
  add_foreign_key "mcp_oauth_refresh_tokens", "mcp_servers"
  add_foreign_key "mcp_provider_oauth_states", "mcp_servers"
  add_foreign_key "plans", "plan_types"
  add_foreign_key "plans", "users"
end
