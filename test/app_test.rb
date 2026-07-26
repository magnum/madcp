# frozen_string_literal: true

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_OAUTH_USERNAME"] = "admin"
ENV["MADCP_OAUTH_PASSWORD"] = "secret"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
ENV["MADCP_ALLOWED_HOSTS"] = "localhost,127.0.0.1"
ENV["MADCP_ALLOW_WRITE"] = "false"

require "minitest/autorun"
require "rack/mock"
require "uri"
require_relative "../server"

class AppTest < Minitest::Test
  def setup
    @request = Rack::MockRequest.new(APP)
  end

  def test_lists_discovered_integrations
    response = @request.get(
      "/servers/?format=json",
      "HTTP_HOST" => "localhost",
      "HTTP_ACCEPT" => "application/json",
    )

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal %w[basecamp fattureincloud hey], payload.fetch("servers").map { |item| item.fetch("id") }
  end

  def test_lists_tools_and_write_state
    response = @request.get("/servers/hey/tools", "HTTP_HOST" => "localhost")

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal 30, payload.fetch("tools").length
    compose = payload.fetch("tools").find { |tool| tool["name"] == "hey_compose" }
    assert_equal true, compose.fetch("write")
    assert_equal false, compose.fetch("enabled")
  end

  def test_basecamp_tool_parity
    response = @request.get("/servers/basecamp/tools", "HTTP_HOST" => "localhost")

    assert_equal 200, response.status
    tools = JSON.parse(response.body).fetch("tools")
    assert_equal 38, tools.length
    assert tools.any? { |tool| tool["name"] == "basecamp_assign" }
    assert tools.any? { |tool| tool["name"] == "basecamp_skill" }
  end

  def test_mcp_requires_bearer
    response = @request.post(
      "/servers/hey/mcp",
      "HTTP_HOST" => "localhost",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list"),
    )

    assert_equal 401, response.status
    assert_includes response["www-authenticate"], "resource_metadata"
  end

  def test_mcp_initialize_with_static_bearer
    response = @request.post(
      "/servers/hey/mcp",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "test", version: "1.0" },
        },
      ),
    )

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal "hey", payload.dig("result", "serverInfo", "name")
  end

  def test_mcp_lists_and_reads_skill_resource
    list = @request.post(
      "/servers/hey/mcp",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(jsonrpc: "2.0", id: 2, method: "resources/list", params: {}),
    )
    assert_equal "hey://skill", JSON.parse(list.body).dig("result", "resources", 0, "uri")

    read = @request.post(
      "/servers/hey/mcp",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        jsonrpc: "2.0",
        id: 3,
        method: "resources/read",
        params: { uri: "hey://skill" },
      ),
    )
    assert_includes JSON.parse(read.body).dig("result", "contents", 0, "text"), "name: hey"
  end


  def test_mcp_list_tools_preserve_integration_execution_context
    cases = {
      "hey" => ["hey_boxes", { ok: true, data: [{ id: 1, name: "imbox" }] }],
      "basecamp" => ["basecamp_projects", { ok: true, data: [{ id: 1, name: "Demo" }] }],
    }

    cases.each do |server_id, (tool_name, cli_output)|
      client = REGISTRY.fetch(server_id).instance_variable_get(:@client)
      client.define_singleton_method(:run) { |*| JSON.generate(cli_output) }

      response = @request.post(
        "/servers/#{server_id}/mcp",
        "HTTP_HOST" => "localhost",
        "HTTP_AUTHORIZATION" => "Bearer static-test-token",
        "CONTENT_TYPE" => "application/json",
        input: JSON.generate(
          jsonrpc: "2.0",
          id: 10,
          method: "tools/call",
          params: { name: tool_name, arguments: {} },
        ),
      )
      payload = JSON.parse(response.body)

      assert_nil payload["error"], payload.dig("error", "data")
      assert_includes payload.dig("result", "content", 0, "text"), "\"name\":\""
    ensure
      client.singleton_class.remove_method(:run) if client&.singleton_methods&.include?(:run)
    end
  end

  def test_direct_write_tool_is_blocked_before_cli_execution
    response = @request.post(
      "/servers/hey/tools/hey_compose",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(subject: "No send", message: "Blocked"),
    )

    assert_equal 403, response.status
    assert_equal "write method disabled", JSON.parse(response.body).fetch("error")
  end

  def test_oauth_dynamic_registration_and_metadata
    metadata = @request.get(
      "/.well-known/oauth-authorization-server/servers/hey",
      "HTTP_HOST" => "localhost",
    )
    assert_equal 200, metadata.status
    assert_equal "http://localhost:8765/servers/hey", JSON.parse(metadata.body).fetch("issuer")

    registration = @request.post(
      "/servers/hey/auth/register",
      "HTTP_HOST" => "localhost",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
        token_endpoint_auth_method: "none",
      ),
    )
    assert_equal 201, registration.status
    assert JSON.parse(registration.body).fetch("client_id")
  end

  def test_oauth_pkce_flow_preserves_client_state
    integration = REGISTRY.fetch("hey")
    provider = Madcp::OAuthProvider.new(config: CONFIG, integration: integration)
    client = provider.register_client(
      "redirect_uris" => ["https://client.example/callback"],
      "token_endpoint_auth_method" => "none",
    )
    verifier = "a" * 64
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    login_url = provider.start_authorization(
      "client_id" => client["client_id"],
      "redirect_uri" => "https://client.example/callback",
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "client-state",
    )
    login_state = URI.decode_www_form(URI(login_url).query).to_h.fetch("state")
    callback_url = provider.authorize_login(
      username: "admin",
      password: "secret",
      state: login_state,
    )
    callback = URI.decode_www_form(URI(callback_url).query).to_h

    assert_equal "client-state", callback.fetch("state")
    tokens = provider.token_request(
      "grant_type" => "authorization_code",
      "client_id" => client["client_id"],
      "code" => callback.fetch("code"),
      "code_verifier" => verifier,
    )
    assert provider.load_access_token(tokens.fetch(:access_token))
  end
end
