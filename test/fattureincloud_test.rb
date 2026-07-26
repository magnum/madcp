# frozen_string_literal: true

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_AUTH_USERNAME"] = "admin"
ENV["MADCP_AUTH_PASSWORD"] = "secret"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
ENV["MADCP_ALLOWED_HOSTS"] = "localhost,127.0.0.1"
ENV["MADCP_ALLOW_WRITE"] = "false"

require "base64"
require "minitest/autorun"
require "rack/mock"
require "tmpdir"
require "uri"
require_relative "../server"

class FattureInCloudTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    %i[get post put delete].each do |method|
      define_method(method) do |path, **options|
        @calls << [method, path, options]
        { status: 200, headers: { "content-type" => "application/json" }, body: { "ok" => true } }
      end
    end

    def request(method, path, **options)
      @calls << [method, path, options]
      { status: 200, headers: { "content-type" => "application/json" }, body: { "access_token" => "token" } }
    end
  end

  def setup
    @old_company_id = ENV["FATTUREINCLOUD_COMPANY_ID"]
    ENV["FATTUREINCLOUD_COMPANY_ID"] = "42"
    @integration = Madcp::Servers::FattureInCloud::Server.new(config: CONFIG)
    @client = RecordingClient.new
    @integration.instance_variable_set(:@client, @client)
  end

  def teardown
    if @old_company_id
      ENV["FATTUREINCLOUD_COMPANY_ID"] = @old_company_id
    else
      ENV.delete("FATTUREINCLOUD_COMPANY_ID")
    end
  end

  def test_tool_catalog_contains_reads_and_write_gated_mutations
    tools = @integration.tool_catalog

    assert_equal 22, tools.length
    assert tools.any? { |tool| tool[:name] == "fattureincloud_companies" && !tool[:write] }
    assert tools.any? { |tool| tool[:name] == "fattureincloud_archive_document_create" && tool[:write] }
    assert tools.select { |tool| tool[:write] }.all? { |tool| !tool[:enabled] }
    assert_raises(SecurityError) do
      @integration.call_tool(
        "fattureincloud_client_create",
        company_id: "42",
        payload: { "data" => { "name" => "Blocked" } },
      )
    end
    assert_empty @client.calls
  end

  def test_list_path_params_and_persisted_company_fallback
    @integration.call_tool(
      "fattureincloud_issued_documents",
      type: "invoice",
      fields: "id,total_gross",
      page: 2,
      per_page: 25,
      q: "status=paid",
    )

    method, path, options = @client.calls.fetch(0)
    assert_equal :get, method
    assert_equal "/c/42/issued_documents", path
    assert_equal "invoice", options.dig(:query, :type)
    assert_equal 2, options.dig(:query, :page)
    assert_equal "id,total_gross", options.dig(:query, :fields)
  end

  def test_company_id_is_required_without_argument_or_default
    ENV.delete("FATTUREINCLOUD_COMPANY_ID")

    error = assert_raises(RuntimeError) do
      @integration.call_tool("fattureincloud_company_info", {})
    end
    assert_includes error.message, "company_id is required"
  end

  def test_delete_accepts_id_and_company_without_payload_when_writes_enabled
    old_write_override = ENV["FATTUREINCLOUD_ALLOW_WRITE"]
    ENV["FATTUREINCLOUD_ALLOW_WRITE"] = "true"
    integration = Madcp::Servers::FattureInCloud::Server.new(config: CONFIG)
    client = RecordingClient.new
    integration.instance_variable_set(:@client, client)

    integration.call_tool(
      "fattureincloud_client_delete",
      id: "123",
      company_id: "42",
    )

    method, path, options = client.calls.fetch(0)
    assert_equal :delete, method
    assert_equal "/c/42/entities/clients/123", path
    assert_nil options[:body]
    required = integration.tool_catalog.find { |tool| tool[:name] == "fattureincloud_client_delete" }
                          .dig(:input_schema, :required)
    assert_equal ["id"], required
  ensure
    ENV["FATTUREINCLOUD_ALLOW_WRITE"] = old_write_override
  end

  def test_apply_oauth_result_persists_access_refresh_and_full_json
    path = File.join(@integration.data_dir, "oauth_token.json")
    payload = {
      status: 200,
      body: {
        "access_token" => "access-from-oauth",
        "refresh_token" => "refresh-from-oauth",
        "token_type" => "bearer",
        "expires_in" => 3600,
      },
    }
    @integration.define_singleton_method(:auth_status) { { authenticated: true } }

    assert @integration.apply_oauth_result!(payload)
    assert_equal "access-from-oauth", ENV["FATTUREINCLOUD_TOKEN"]
    assert_equal "refresh-from-oauth", ENV["FATTUREINCLOUD_REFRESH_TOKEN"]
    assert File.file?(path)
    stored = JSON.parse(File.read(path))
    assert_equal "access-from-oauth", stored.fetch("access_token")
    assert_equal "refresh-from-oauth", stored.fetch("refresh_token")
  ensure
    ENV.delete("FATTUREINCLOUD_TOKEN")
    ENV.delete("FATTUREINCLOUD_REFRESH_TOKEN")
    File.delete(path) if path && File.file?(path)
    @integration.singleton_class.remove_method(:auth_status) if @integration
  end

  def test_oauth_uses_exact_callback_and_json_code_exchange
    old_client_id = ENV["FATTUREINCLOUD_CLIENT_ID"]
    old_client_secret = ENV["FATTUREINCLOUD_CLIENT_SECRET"]
    ENV["FATTUREINCLOUD_CLIENT_ID"] = "client-id"
    ENV["FATTUREINCLOUD_CLIENT_SECRET"] = "client-secret"
    callback_url = "https://madcp.example/servers/fattureincloud/oauth_callback"

    authorization = URI(@integration.oauth_call(callback_url: callback_url, state: "random-state")[:authorization_url])
    query = URI.decode_www_form(authorization.query).to_h
    assert_equal callback_url, query.fetch("redirect_uri")
    assert_equal "random-state", query.fetch("state")
    assert_equal Madcp::Servers::FattureInCloud::Server::DEFAULT_SCOPES, query.fetch("scope")

    result = @integration.oauth_exchange(callback_url: callback_url, params: { "code" => "oauth-code" })
    method, path, options = @client.calls.last
    assert_equal :post, method
    assert_equal "/oauth/token", path
    assert_equal false, options[:bearer]
    assert_equal callback_url, options.dig(:body, :redirect_uri)
    assert_equal "oauth-code", options.dig(:body, :code)
    assert_equal 200, result[:status]
  ensure
    ENV["FATTUREINCLOUD_CLIENT_ID"] = old_client_id
    ENV["FATTUREINCLOUD_CLIENT_SECRET"] = old_client_secret
  end

  def test_net_http_client_encodes_query_and_bearer_without_network
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { JSON.generate("data" => [{ "id" => 1 }]) }
    response.define_singleton_method(:each_header) do |&block|
      next enum_for(:each_header) unless block

      block.call("content-type", "application/json")
    end
    captured_request = nil
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      captured_request = request
      response
    end
    client = Madcp::Servers::FattureInCloud::Client.new(token: "api-token")

    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &block| block.call(fake_http) }
    result = client.get("/c/42/entities/clients", query: { page: 2, q: "name=Acme" })

    assert_equal 200, result[:status]
    assert_equal "Bearer api-token", captured_request["Authorization"]
    query = URI.decode_www_form(captured_request.uri.query).to_h
    assert_equal({ "page" => "2", "q" => "name=Acme" }, query)
  ensure
    Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
      original_start.call(*args, **kwargs, &block)
    end if original_start
  end

  def test_mcp_tool_call_preserves_fatture_integration_context
    global = REGISTRY.fetch("fattureincloud")
    original_client = global.instance_variable_get(:@client)
    client = RecordingClient.new
    global.instance_variable_set(:@client, client)
    request = Rack::MockRequest.new(APP)
    response = request.post(
      "/servers/fattureincloud/mcp",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        jsonrpc: "2.0",
        id: 20,
        method: "tools/call",
        params: { name: "fattureincloud_companies", arguments: {} },
      ),
    )

    payload = JSON.parse(response.body)
    assert_nil payload["error"], payload.dig("error", "data")
    assert_equal "/user/companies", client.calls.fetch(0).fetch(1)
    assert_includes payload.dig("result", "content", 0, "text"), "\"ok\": true"
  ensure
    global.instance_variable_set(:@client, original_client) if global
  end
end

class OAuthTokenRetrievalTest < Minitest::Test
  class FakeIntegration < Madcp::Integration
    server_id "fake-oauth"
    display_name "Fake OAuth"
    oauth_token_retrieval true

    attr_reader :exchange_params

    def auth_status = { authenticated: false }
    def auth_fields = []
    def apply_credentials(_params) = true
    def clear_credentials! = nil
    def configure_tools = nil

    def oauth_call(callback_url:, state:)
      query = URI.encode_www_form(redirect_uri: callback_url, state: state)
      { authorization_url: "https://provider.example/authorize?#{query}" }
    end

    def oauth_exchange(callback_url:, params:)
      @exchange_params = params
      {
        status: 200,
        headers: { "content-type" => "application/json", "x-request-id" => "safe-id" },
        body: {
          "access_token" => "access-secret",
          "refresh_token" => "refresh-secret",
          "client_secret" => "never-display-this",
          "redirect_uri" => callback_url,
        },
      }
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir
    config = Madcp::Config.new(root: @tmpdir)
    registry = Madcp::Registry.new(config: config)
    registry.register(FakeIntegration)
    renderer = Madcp::Renderer.new(views_dir: File.expand_path("../views", __dir__))
    @app = Madcp::App.configured(config: config, registry: registry, renderer: renderer)
    @request = Rack::MockRequest.new(@app)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_launch_requires_basic_auth
    response = @request.post(
      "/servers/fake-oauth/oauth",
      "HTTP_HOST" => "localhost",
    )

    assert_equal 401, response.status
    assert_includes response["WWW-Authenticate"].to_s, "Basic"
    assert_nil response["location"]
  end

  def test_launch_callback_and_one_time_state
    launch = launch_oauth
    authorization_uri = URI(launch["location"])
    authorization_params = URI.decode_www_form(authorization_uri.query).to_h
    state = authorization_params.fetch("state")
    assert_equal "http://localhost:8765/servers/fake-oauth/oauth_callback",
                 authorization_params.fetch("redirect_uri")

    callback = @request.get(
      "/servers/fake-oauth/oauth_callback?#{URI.encode_www_form(state: state, code: "abc", scope: %w[one two], client_secret: "query-secret")}",
      {
        "HTTP_HOST" => "localhost",
        "HTTP_COOKIE" => "private=cookie",
        "HTTP_X_PRIVATE" => "do-not-echo",
      }.merge(basic_auth),
    )

    assert_equal 200, callback.status
    assert_equal "no-store", callback["cache-control"]
    assert_equal "no-referrer", callback["referrer-policy"]
    assert_includes callback.body, "access-secret"
    assert_includes callback.body, "refresh-secret"
    assert_includes callback.body, "abc"
    assert_includes callback.body, "[REDACTED]"
    refute_includes callback.body, "never-display-this"
    refute_includes callback.body, "query-secret"
    refute callback.headers.keys.any? { |key| key.match?(/access|refresh|private|cookie/i) }
    refute_includes callback.headers.values.join(" "), "access-secret"
    refute_includes callback.headers.values.join(" "), "refresh-secret"

    reused = @request.get(
      "/servers/fake-oauth/oauth_callback?#{URI.encode_www_form(state: state, code: "again")}",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth),
    )
    assert_equal 400, reused.status
    assert_includes reused["content-type"], "application/json"
    assert_equal "invalid, expired, or already used OAuth state", JSON.parse(reused.body).fetch("error")
  end

  def test_invalid_and_expired_state_are_rejected
    invalid = @request.get(
      "/servers/fake-oauth/oauth_callback?state=not-valid&code=abc",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth),
    )
    assert_equal 400, invalid.status
    assert_includes invalid["content-type"], "application/json"

    launch = launch_oauth
    state = URI.decode_www_form(URI(launch["location"]).query).to_h.fetch("state")
    @app.settings.oauth_retrieval_states.fetch(state)[:expires_at] = Time.now.to_i - 1
    expired = @request.get(
      "/servers/fake-oauth/oauth_callback?#{URI.encode_www_form(state: state, code: "abc")}",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth),
    )
    assert_equal 400, expired.status
  end

  private

  def basic_auth(username = "admin", password = "secret")
    { "HTTP_AUTHORIZATION" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end

  def launch_oauth
    response = @request.post(
      "/servers/fake-oauth/oauth",
      { "HTTP_HOST" => "localhost" }.merge(basic_auth),
    )
    assert_equal 302, response.status
    response
  end
end
