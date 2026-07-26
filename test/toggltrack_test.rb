# frozen_string_literal: true

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_OAUTH_USERNAME"] = "admin"
ENV["MADCP_OAUTH_PASSWORD"] = "secret"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
ENV["MADCP_ALLOWED_HOSTS"] = "localhost,127.0.0.1"
ENV["MADCP_ALLOW_WRITE"] = "false"

require "base64"
require "minitest/autorun"
require "rack/mock"
require_relative "../server"

class TogglTrackTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    %i[get post put patch delete].each do |method|
      define_method(method) do |path, **options|
        @calls << [method, path, options]
        { status: 200, headers: {}, body: { "ok" => true, "path" => path } }
      end
    end
  end

  def setup
    @old_workspace = ENV["TOGGLTRACK_WORKSPACE_ID"]
    @old_organization = ENV["TOGGLTRACK_ORGANIZATION_ID"]
    ENV["TOGGLTRACK_WORKSPACE_ID"] = "99"
    ENV["TOGGLTRACK_ORGANIZATION_ID"] = "7"
    @integration = Madcp::Servers::TogglTrack::Server.new(config: CONFIG)
    @client = RecordingClient.new
    @integration.instance_variable_set(:@client, @client)
  end

  def teardown
    if @old_workspace
      ENV["TOGGLTRACK_WORKSPACE_ID"] = @old_workspace
    else
      ENV.delete("TOGGLTRACK_WORKSPACE_ID")
    end
    if @old_organization
      ENV["TOGGLTRACK_ORGANIZATION_ID"] = @old_organization
    else
      ENV.delete("TOGGLTRACK_ORGANIZATION_ID")
    end
  end

  def test_catalog_contains_reads_and_write_gated_mutations
    tools = @integration.tool_catalog

    assert_equal 22, tools.length
    assert tools.any? { |tool| tool[:name] == "toggltrack_me" && !tool[:write] }
    assert tools.any? { |tool| tool[:name] == "toggltrack_time_entry_start" && tool[:write] }
    assert tools.select { |tool| tool[:write] }.all? { |tool| !tool[:enabled] }
    assert_raises(SecurityError) do
      @integration.call_tool("toggltrack_time_entry_stop", time_entry_id: "1")
    end
    assert_empty @client.calls
  end

  def test_workspace_scoped_list_uses_persisted_default
    @integration.call_tool("toggltrack_projects", active: "true", page: 1)

    method, path, options = @client.calls.fetch(0)
    assert_equal :get, method
    assert_equal "/workspaces/99/projects", path
    assert_equal "true", options.dig(:query, :active)
    assert_equal 1, options.dig(:query, :page)
  end

  def test_workspace_id_is_required_without_argument_or_default
    ENV.delete("TOGGLTRACK_WORKSPACE_ID")

    error = assert_raises(RuntimeError) do
      @integration.call_tool("toggltrack_tags", {})
    end
    assert_includes error.message, "workspace_id is required"
  end

  def test_time_entry_start_forces_running_duration
    old = ENV["TOGGLTRACK_ALLOW_WRITE"]
    ENV["TOGGLTRACK_ALLOW_WRITE"] = "true"
    integration = Madcp::Servers::TogglTrack::Server.new(config: CONFIG)
    client = RecordingClient.new
    integration.instance_variable_set(:@client, client)

    integration.call_tool(
      "toggltrack_time_entry_start",
      description: "Deep work",
      project_id: 12,
      tags: %w[focus],
    )

    method, path, options = client.calls.fetch(0)
    assert_equal :post, method
    assert_equal "/workspaces/99/time_entries", path
    assert_equal(-1, options.dig(:body, "duration"))
    assert_equal 99, options.dig(:body, "workspace_id")
    assert_equal "Deep work", options.dig(:body, "description")
    assert_equal "madcp", options.dig(:body, "created_with")
  ensure
    ENV["TOGGLTRACK_ALLOW_WRITE"] = old
  end

  def test_net_http_client_uses_basic_auth_token_without_network
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { JSON.generate("id" => 1) }
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
    client = Madcp::Servers::TogglTrack::Client.new(token: "secret-token")

    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &block| block.call(fake_http) }
    result = client.get("/me")

    assert_equal 200, result[:status]
    expected = "Basic #{Base64.strict_encode64("secret-token:api_token")}"
    assert_equal expected, captured_request["Authorization"]
    assert_equal "application/json", captured_request["Accept"]
  ensure
    Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
      original_start.call(*args, **kwargs, &block)
    end if original_start
  end

  def test_mcp_tool_call_preserves_toggl_integration_context
    registry_integration = REGISTRY.fetch("toggltrack")
    old_client = registry_integration.instance_variable_get(:@client)
    client = RecordingClient.new
    registry_integration.instance_variable_set(:@client, client)
    request = Rack::MockRequest.new(APP)

    response = request.post(
      "/servers/toggltrack/mcp",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "toggltrack_organization",
          arguments: {},
        },
      ),
    )

    assert_equal 200, response.status
    assert_equal "/organizations/7", client.calls.fetch(0)[1]
  ensure
    registry_integration.instance_variable_set(:@client, old_client) if registry_integration
  end
end
