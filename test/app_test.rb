# frozen_string_literal: true

require_relative "test_helper"

require "base64"
require "fileutils"
require "minitest/autorun"
require "rack/mock"
require "stringio"
require "uri"
require_relative "../server"

class AppTest < Minitest::Test
  def setup
    @request = Rack::MockRequest.new(APP)
  end

  def basic_auth(username = "user1", password = "secret")
    { "HTTP_AUTHORIZATION" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end

  def test_operator_ui_requires_basic_auth
    response = @request.get("/servers/", "HTTP_HOST" => "localhost")
    assert_equal 401, response.status
    assert_includes response["WWW-Authenticate"].to_s, "Basic"
  end

  def test_operator_ui_accepts_bearer_from_auth_token
    response = @request.get(
      "/servers/?format=json",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
    )
    assert_equal 200, response.status
  end

  def test_operator_ui_basic_auth_validates_auth_users
    response = @request.get(
      "/servers/?format=json",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth("user1", "secret")),
    )
    assert_equal 200, response.status
  end

  def test_operator_ui_rejects_token_as_basic_password
    response = @request.get(
      "/servers/?format=json",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth("user1", "static-test-token")),
    )
    assert_equal 401, response.status
  end

  def test_app_auth_parses_tokens_and_disabled_lines
    dir = Dir.mktmpdir
    tokens = File.join(dir, "auth_tokens")
    users = File.join(dir, "auth_users")
    File.write(
      tokens,
      <<~TOKENS,
        live-token-one # desktop
        # revoked-token # old
        live-token-two # cowork
      TOKENS
    )
    File.write(users, "")
    auth = Madcp::AppAuth.new(tokens_path: tokens, users_path: users, secret: "pepper")
    assert auth.valid_bearer?("live-token-one")
    assert auth.valid_bearer?("live-token-two")
    refute auth.valid_bearer?("revoked-token")
    assert_equal "desktop", auth.lookup_bearer("live-token-one").label

    File.write(tokens, "live-token-one # desktop\n# live-token-two # cowork\n")
    File.utime(Time.now + 2, Time.now + 2, tokens)
    assert auth.valid_bearer?("live-token-one")
    refute auth.valid_bearer?("live-token-two")
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_app_auth_validates_users_hmac_and_disabled_lines
    dir = Dir.mktmpdir
    tokens = File.join(dir, "auth_tokens")
    users = File.join(dir, "auth_users")
    secret = "pepper"
    digest = Madcp::AppAuth.hash_password("hunter2", secret: secret)
    File.write(tokens, "")
    File.write(users, "alice:#{digest} # alice\n# bob:#{digest} # bob\n")
    auth = Madcp::AppAuth.new(tokens_path: tokens, users_path: users, secret: secret)
    assert auth.valid_basic?("alice", "hunter2")
    refute auth.valid_basic?("alice", "wrong")
    refute auth.valid_basic?("bob", "hunter2")
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_requests_are_logged_to_file_and_stdout
    log_path = ENV.fetch("MADCP_REQUEST_LOG")
    File.write(log_path, "")
    stdout = StringIO.new
    logger = Madcp::RequestLogger.new(path: log_path, io: stdout, max_chars: 2_000)

    logger.log(
      ip: "203.0.113.9",
      method: "POST",
      path: "/servers/toggltrack/mcp",
      status: 200,
      duration_ms: 12,
      user_agent: "test-agent",
      request_body: JSON.generate(
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "toggltrack_me",
          arguments: { with_related_data: true, access_token: "secret-value" },
        },
      ),
    )

    file_line = File.read(log_path).lines.last.to_s
    out_line = stdout.string.lines.last.to_s

    assert_equal file_line, out_line
    assert_includes file_line, "madcp.request"
    assert_includes file_line, "ip=203.0.113.9"
    assert_includes file_line, "method=POST"
    assert_includes file_line, "path=/servers/toggltrack/mcp"
    assert_includes file_line, "server_id=toggltrack"
    assert_includes file_line, "mcp_method=tools/call"
    assert_includes file_line, "command=toggltrack_me"
    assert_includes file_line, "arguments="
    assert_includes file_line, "[REDACTED]"
    refute_includes file_line, "secret-value"
    refute_includes file_line, "response="

    before = File.size(log_path)
    response = @request.get(
      "/servers/?format=json",
      { "HTTP_HOST" => "localhost", "HTTP_ACCEPT" => "application/json" }.merge(basic_auth),
    )
    assert_equal 200, response.status
    assert File.size(log_path) > before
    assert_includes File.read(log_path), "/servers/?format=json"
  end

  def test_layout_uses_shared_header_footer_partials
    html = RENDERER.page(
      "servers",
      title: "MadCP integrations",
      integrations: REGISTRY.all,
      public_url: CONFIG.public_url,
      repo_url: "https://github.com/magnum/madcp",
    )

    assert_includes html, 'id="theme-toggle"'
    assert_includes html, 'href="/logout"'
    assert_includes html, ">MadCP</a>"
    assert_includes html, "MIT License"
    assert_includes html, "/blob/main/LICENSE"
    assert_includes html, "text-5xl"
    assert_includes html, "Integrations"
    assert_includes html, "text-3xl"
    assert_includes html, "text-2xl"
    assert_includes html, 'data-auth-refresh'
    assert_includes html, "refreshAuthStatus"
    assert_includes html, "hidden md:inline"
    assert_includes html, "flex flex-nowrap items-center justify-end gap-2"
    assert_includes html, 'href="/servers/hey/auth"'
    assert_includes html, 'href="/servers/hey/tools"'
    assert_includes html, "data-auth-badge-ok"
    assert_includes html, "data-auth-badge-bad"
    assert_includes html, "data-auth-badge-label"
    assert_includes html, "inline-flex h-10 w-10 shrink-0 items-center justify-center gap-2 whitespace-nowrap rounded-lg border font-semibold md:w-auto md:px-4"
    refute_includes html, "whitespace-nowrap rounded-full border px-4 py-2"
    refute_includes html, "tracking-[0.2em]"
  end

  def test_auth_status_endpoint_returns_json
    integration = REGISTRY.fetch("toggltrack")
    integration.define_singleton_method(:auth_status) do |force: false|
      { authenticated: false, error: "Toggl Track API token is not configured", force: force }
    end

    response = @request.get(
      "/servers/toggltrack/auth/status?refresh=1",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth),
    )

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal "toggltrack", payload.fetch("server_id")
    assert_equal false, payload.fetch("authenticated")
    assert_equal true, payload.fetch("refreshed")
    assert_equal 600, payload.fetch("cache_ttl")
    assert_includes payload.fetch("error"), "not configured"
  ensure
    integration.singleton_class.remove_method(:auth_status) if integration
  end

  def test_auth_status_cache_reuses_probe_until_forced
    integration = REGISTRY.fetch("hey")
    calls = 0
    integration.define_singleton_method(:auth_status_cache_ttl) { 60 }
    integration.define_singleton_method(:fetch_auth_status) do
      calls += 1
      { authenticated: true, source: "cache-test", calls: calls }
    end
    integration.invalidate_auth_status!

    first = integration.auth_status
    second = integration.auth_status
    forced = integration.auth_status(force: true)

    assert_equal 1, first[:calls]
    assert_equal 1, second[:calls]
    assert_equal 2, forced[:calls]
    assert_equal 2, calls
  ensure
    integration.invalidate_auth_status!
    integration.singleton_class.remove_method(:fetch_auth_status) if integration
    integration.singleton_class.remove_method(:auth_status_cache_ttl) if integration
  end

  def test_logout_challenges_basic_auth_again
    response = @request.get("/logout", "HTTP_HOST" => "localhost")
    assert_equal 401, response.status
    assert_includes response["WWW-Authenticate"].to_s, 'Basic realm="MadCP"'
    assert_includes response.body, "Signed out"
  end

  def test_lists_discovered_integrations
    response = @request.get(
      "/servers/?format=json",
      { "HTTP_HOST" => "localhost", "HTTP_ACCEPT" => "application/json" }.merge(basic_auth),
    )

    assert_equal 200, response.status
    payload = JSON.parse(response.body)
    assert_equal(
      %w[basecamp bluesky fattureincloud googleworkspace hey toggltrack twitter],
      payload.fetch("servers").map { |item| item.fetch("id") },
    )
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

  def test_every_integration_provides_authentication_help
    REGISTRY.all.each do |integration|
      help = integration.auth_help_content
      assert_kind_of Hash, help
      assert help[:title]
      assert help[:steps]&.any?
    end

    google_help = REGISTRY.fetch("googleworkspace").auth_help_content
    assert google_help[:commands].any? { |command| command[:value] == "gws auth export --unmasked" }
  end

  def test_authentication_views_use_readable_copyable_help
    integration = REGISTRY.fetch("googleworkspace")
    integration.define_singleton_method(:auth_status) { |force: false| { authenticated: false } }

    html = RENDERER.page(
      "auth",
      title: integration.display_name,
      integration: integration,
      public_url: CONFIG.public_url,
      repo_url: "https://github.com/magnum/madcp",
      state: nil,
      error: nil,
      message: nil,
    )

    assert_includes html, "gws auth export --unmasked"
    assert_includes html, "copyAuthCommand(this)"
    assert_includes html, "data-auth-refresh"
    assert_includes html, "refresh=1"
    assert_includes html, "whitespace-nowrap"
    assert_includes html, "pre-filled from the current environment"
    refute_includes html, "<pre"
  ensure
    integration.singleton_class.remove_method(:auth_status) if integration
  end

  def test_sanitize_env_value_strips_hash_comments
    assert_equal "proj-1", Madcp.sanitize_env_value("  proj-1  ")
    assert_equal "", Madcp.sanitize_env_value("# optional")
    assert_equal "", Madcp.sanitize_env_value("#optional")
    assert_equal "", Madcp.sanitize_env_value("# required")
    assert_equal "proj-1", Madcp.sanitize_env_value("proj-1 # optional")
    assert_equal "abc123", Madcp.sanitize_env_value("abc123 # required")
    assert_equal "token", Madcp.sanitize_env_value("token#trailing-comment")
    assert_equal "https://madcp.example.com", Madcp.sanitize_env_value("https://madcp.example.com")
  end

  def test_apply_env_sanitization_rewrites_process_env
    key = "MADCP_TEST_SANITIZE_#{Process.pid}"
    ENV[key] = "value # required"
    Madcp.apply_env_sanitization!
    assert_equal "value", ENV[key]
  ensure
    ENV.delete(key)
  end

  def test_auth_continue_completes_mcp_oauth_without_integration_credentials
    provider = APP.allocate.providers.fetch("hey")
    client = provider.register_client(
      "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
      "token_endpoint_auth_method" => "none",
    )
    verifier = "c" * 64
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    login_url = provider.start_authorization(
      "client_id" => client["client_id"],
      "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "claude-wait",
    )
    login_state = URI.decode_www_form(URI(login_url).query).to_h.fetch("state")

    response = @request.post(
      "/servers/hey/auth/continue",
      {
        "HTTP_HOST" => "localhost",
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        input: URI.encode_www_form(state: login_state),
      }.merge(basic_auth),
    )

    assert_equal 302, response.status
    location = response["Location"]
    assert_includes location, "https://claude.ai/api/mcp/auth_callback"
    assert_includes location, "code="
    assert_includes location, "state=claude-wait"
  end

  def test_auth_form_prefills_env_backed_fields
    integration = REGISTRY.fetch("googleworkspace")
    integration.define_singleton_method(:auth_status) { |force: false| { authenticated: false } }
    old_project = ENV["GOOGLE_WORKSPACE_PROJECT_ID"]
    ENV["GOOGLE_WORKSPACE_PROJECT_ID"] = "madcp-prefill-project"

    assert_equal "madcp-prefill-project", integration.auth_field_value(
      integration.auth_fields.find { |field| field[:name] == "googleworkspace_project_id" },
    )

    html = RENDERER.page(
      "auth",
      title: integration.display_name,
      integration: integration,
      public_url: CONFIG.public_url,
      repo_url: "https://github.com/magnum/madcp",
      state: nil,
      error: nil,
      message: nil,
    )

    assert_includes html, 'value="madcp-prefill-project"'
  ensure
    if old_project
      ENV["GOOGLE_WORKSPACE_PROJECT_ID"] = old_project
    else
      ENV.delete("GOOGLE_WORKSPACE_PROJECT_ID")
    end
    integration.singleton_class.remove_method(:auth_status) if integration
  end

  def test_integration_list_status_does_not_wrap
    integrations = REGISTRY.all
    integrations.each do |integration|
      integration.define_singleton_method(:auth_status) { |force: false| { authenticated: false } }
    end

    html = RENDERER.page(
      "servers",
      title: "MadCP integrations",
      integrations: integrations,
      public_url: CONFIG.public_url,
      repo_url: "https://github.com/magnum/madcp",
    )

    assert_includes html, "Not authenticated"
    assert_includes html, "whitespace-nowrap"
    assert_includes html, 'data-auth-refresh'
  ensure
    integrations&.each do |integration|
      integration.singleton_class.remove_method(:auth_status)
    end
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
    callback_url = provider.authorize_login(state: login_state)
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

  def test_oauth_clients_and_tokens_persist_across_provider_restarts
    require "tmpdir"
    Dir.mktmpdir("madcp-oauth") do |root|
      config = Madcp::Config.new(root: root)
      integration = REGISTRY.fetch("googleworkspace")
      provider = Madcp::OAuthProvider.new(config: config, integration: integration)
      client = provider.register_client(
        "redirect_uris" => ["https://client.example/callback"],
        "token_endpoint_auth_method" => "none",
      )
      verifier = "b" * 64
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      login_url = provider.start_authorization(
        "client_id" => client["client_id"],
        "redirect_uri" => "https://client.example/callback",
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "persist-me",
      )
      login_state = URI.decode_www_form(URI(login_url).query).to_h.fetch("state")
      callback_url = provider.authorize_login(state: login_state)
      code = URI.decode_www_form(URI(callback_url).query).to_h.fetch("code")
      tokens = provider.token_request(
        "grant_type" => "authorization_code",
        "client_id" => client["client_id"],
        "code" => code,
        "code_verifier" => verifier,
      )

      restarted = Madcp::OAuthProvider.new(config: config, integration: integration)
      assert restarted.load_access_token(tokens.fetch(:access_token))

      refreshed = restarted.token_request(
        "grant_type" => "refresh_token",
        "client_id" => client["client_id"],
        "refresh_token" => tokens.fetch(:refresh_token),
      )
      assert restarted.load_access_token(refreshed.fetch(:access_token))

      again = Madcp::OAuthProvider.new(config: config, integration: integration)
      assert again.load_access_token(refreshed.fetch(:access_token))
      assert_raises(Madcp::OAuthProvider::OAuthError) do
        again.token_request(
          "grant_type" => "refresh_token",
          "client_id" => client["client_id"],
          "refresh_token" => tokens.fetch(:refresh_token),
        )
      end
    end
  end
end
