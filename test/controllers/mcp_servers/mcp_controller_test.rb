# frozen_string_literal: true

require "test_helper"

class McpServers::McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["API_KEY_HMAC_SECRET_KEY"] ||= "test-api-key-hmac-secret"
    McpServer.discover!
    @user = User.find_or_create_by!(email: "user1@madcp.local") do |user|
      user.firstname = "User"
      user.lastname = "One"
      user.password = "madcp-dev-password"
      user.password_confirmation = "madcp-dev-password"
    end
    @raw_token = @user.api_key!
  end

  test "mcp endpoint rejects missing bearer" do
    post mcp_mcp_server_path("teslamate"),
         params: { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }.to_json,
         headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
  end

  test "mcp endpoint accepts api key bearer" do
    body = {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "test", version: "1.0" },
      },
    }
    post mcp_mcp_server_path("teslamate"),
         params: body.to_json,
         headers: {
           "CONTENT_TYPE" => "application/json",
           "AUTHORIZATION" => "Bearer #{@raw_token}",
         }
    assert_includes [200, 202], response.status
  end
end
