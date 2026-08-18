# frozen_string_literal: true

require "test_helper"

class McpServersControllerTest < ActionDispatch::IntegrationTest
  setup do
    ENV["API_KEY_HMAC_SECRET_KEY"] ||= "test-api-key-hmac-secret"
    McpServer.discover!
    @user = users(:one)
  end

  test "index requires session" do
    get mcp_servers_path
    assert_response :redirect
  end

  test "index renders for signed in user" do
    post sign_in_path, params: { email: @user.email, password: "password123" }
    get mcp_servers_path
    assert_response :success
    assert_match(/Integrations/, response.body)
    assert_match(/teslamate/, response.body)
  end
end
