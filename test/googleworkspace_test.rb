# frozen_string_literal: true

require "tmpdir"

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_AUTH_USERNAME"] = "admin"
ENV["MADCP_AUTH_PASSWORD"] = "secret"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
ENV["MADCP_ALLOWED_HOSTS"] = "localhost,127.0.0.1"
ENV["MADCP_ALLOW_WRITE"] = "false"
ENV["MADCP_REQUEST_LOG"] ||= File.join(Dir.tmpdir, "madcp-test-requests-#{Process.pid}.logs")

require "minitest/autorun"
require "rack/mock"
require_relative "../server"

class GoogleWorkspaceTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def api(**options)
      @calls << [:api, options]
      JSON.generate(ok: true)
    end

    def helper(**options)
      @calls << [:helper, options]
      JSON.generate(ok: true)
    end

    def help(path)
      @calls << [:help, path]
      "help"
    end

    def schema(path)
      @calls << [:schema, path]
      "{}"
    end

    def auth_status
      JSON.generate(authenticated: true)
    end
  end

  class RecordingCliClient < Madcp::Servers::GoogleWorkspace::Client
    attr_reader :args

    def run(args, truncate: true)
      @args = [args, truncate]
      "{}"
    end
  end

  def setup
    @integration = Madcp::Servers::GoogleWorkspace::Server.new(config: CONFIG)
    @client = RecordingClient.new
    @integration.instance_variable_set(:@client, @client)
  end

  def test_catalog_has_typed_and_dynamic_tools_with_write_gates
    tools = @integration.tool_catalog

    assert_equal 18, tools.length
    assert tools.any? { |tool| tool[:name] == "googleworkspace_doc" && !tool[:write] }
    assert tools.any? { |tool| tool[:name] == "googleworkspace_sheet_values_append" && tool[:write] }
    assert tools.any? { |tool| tool[:name] == "googleworkspace_api_read" && !tool[:write] }
    assert tools.any? { |tool| tool[:name] == "googleworkspace_api_call" && tool[:write] }
    assert tools.select { |tool| tool[:write] }.all? { |tool| !tool[:enabled] }
  end

  def test_auth_status_accepts_gws_diagnostic_prefix
    @client.define_singleton_method(:auth_status) do
      "Using keyring backend: file\n" \
        '{"auth_method":"oauth2","token_valid":true,"credential_source":"credentials_file"}'
    end

    status = @integration.auth_status

    assert status[:authenticated]
    assert_equal true, status[:token_valid]
  end

  def test_auth_status_accepts_exported_user_credentials_without_token_valid
    path = File.join(@integration.data_dir, "credentials.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      JSON.generate(
        type: "authorized_user",
        client_id: "client.apps.googleusercontent.com",
        client_secret: "secret",
        refresh_token: "refresh",
      ),
    )
    ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"] = path
    @client.define_singleton_method(:auth_status) do
      JSON.generate(
        auth_method: "oauth2",
        plain_credentials_exists: true,
        credential_source: "none",
      )
    end

    status = @integration.auth_status

    assert status[:authenticated]
    assert_equal "authorized_user", status[:credentials_type]
  ensure
    ENV.delete("GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE")
    File.delete(path) if path && File.file?(path)
  end

  def test_auth_status_rejects_token_env_var_when_credentials_file_exists
    path = File.join(@integration.data_dir, "credentials.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      JSON.generate(
        type: "authorized_user",
        client_id: "client.apps.googleusercontent.com",
        client_secret: "secret",
        refresh_token: "refresh",
      ),
    )
    ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"] = path
    ENV["GOOGLE_WORKSPACE_CLI_TOKEN"] = "expired-access-token"
    @client.define_singleton_method(:auth_status) do
      JSON.generate(
        auth_method: "oauth2",
        token_valid: true,
        credential_source: "token_env_var",
        plain_credentials_exists: true,
        has_refresh_token: true,
      )
    end

    status = @integration.auth_status

    refute status[:authenticated]
    assert_includes(
      @integration.send(:authentication_failure_message, status),
      "GOOGLE_WORKSPACE_CLI_TOKEN",
    )
  ensure
    ENV.delete("GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE")
    ENV.delete("GOOGLE_WORKSPACE_CLI_TOKEN")
    File.delete(path) if path && File.file?(path)
  end

  def test_client_omits_cli_token_when_credentials_file_exists
    path = File.join(@integration.data_dir, "credentials-priority.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(type: "authorized_user", client_id: "c", client_secret: "s", refresh_token: "r"))
    ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"] = path
    ENV["GOOGLE_WORKSPACE_CLI_TOKEN"] = "stale-token"

    client = Madcp::Servers::GoogleWorkspace::Client.new
    env = client.instance_variable_get(:@env)

    assert_equal path, env["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"]
    refute env.key?("GOOGLE_WORKSPACE_CLI_TOKEN")
  ensure
    ENV.delete("GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE")
    ENV.delete("GOOGLE_WORKSPACE_CLI_TOKEN")
    File.delete(path) if path && File.file?(path)
  end

  def test_authentication_failure_includes_gws_status_details
    @client.define_singleton_method(:auth_status) do
      JSON.generate(auth_method: "none", plain_credentials_exists: false, token_valid: false)
    end
    message = @integration.send(
      :authentication_failure_message,
      @integration.auth_status,
    )

    assert_includes message, "Google Workspace CLI is not authenticated"
    assert_includes message, "gws auth status"
  end

  def test_credentials_validation_requires_exported_user_or_service_account_json
    error = assert_raises(RuntimeError) do
      @integration.send(
        :validate_credentials_json!,
        "type" => "authorized_user",
        "client_id" => "client",
      )
    end
    assert_includes error.message, "client_secret"
    assert_includes error.message, "refresh_token"

    @integration.send(
      :validate_credentials_json!,
      "type" => "service_account",
      "client_email" => "service@example.test",
      "private_key" => "private",
    )
  end

  def test_typed_sheet_read_maps_to_discovery_api
    @integration.call_tool(
      "googleworkspace_sheet_values",
      spreadsheet_id: "sheet-1",
      range: "Data!A1:C4",
      value_render_option: "FORMULA",
    )

    kind, options = @client.calls.fetch(0)
    assert_equal :api, kind
    assert_equal "sheets", options[:service]
    assert_equal %w[spreadsheets values], options[:resources]
    assert_equal "get", options[:method]
    assert_equal "sheet-1", options.dig(:params, :spreadsheetId)
    assert_equal "Data!A1:C4", options.dig(:params, :range)
  end

  def test_drive_tools_enable_shared_drive_support_by_default
    @integration.call_tool("googleworkspace_drive_file", file_id: "shared-file")
    kind, options = @client.calls.fetch(0)
    assert_equal :api, kind
    assert_equal "drive", options[:service]
    assert_equal true, options.dig(:params, :supportsAllDrives)

    @client.calls.clear
    @integration.call_tool("googleworkspace_drive_files", query: "name contains 'brief'")
    _, list_options = @client.calls.fetch(0)
    assert_equal true, list_options.dig(:params, :supportsAllDrives)
    assert_equal true, list_options.dig(:params, :includeItemsFromAllDrives)
    assert_equal "allDrives", list_options.dig(:params, :corpora)
  end

  def test_drive_generic_read_preserves_explicit_shared_drive_overrides
    @integration.call_tool(
      "googleworkspace_api_read",
      service: "drive",
      resources: ["files"],
      method: "get",
      params: { fileId: "abc", supportsAllDrives: false },
    )

    _, options = @client.calls.fetch(0)
    assert_equal false, options.dig(:params, :supportsAllDrives)
  end

  def test_dynamic_read_rejects_mutations_and_bodies
    error = assert_raises(RuntimeError) do
      @integration.call_tool(
        "googleworkspace_api_read",
        service: "drive",
        resources: ["files"],
        method: "delete",
        params: { fileId: "123" },
      )
    end
    assert_includes error.message, "not classified as read-only"
    assert_empty @client.calls

    error = assert_raises(RuntimeError) do
      @integration.call_tool(
        "googleworkspace_api_read",
        service: "drive",
        resources: ["files"],
        method: "get",
        body: { unsafe: true },
      )
    end
    assert_includes error.message, "cannot include a request body"
    assert_empty @client.calls
  end

  def test_dynamic_write_is_blocked_before_client_execution
    assert_raises(SecurityError) do
      @integration.call_tool(
        "googleworkspace_api_call",
        service: "drive",
        resources: ["files"],
        method: "delete",
        params: { fileId: "123" },
      )
    end
    assert_empty @client.calls
  end

  def test_client_builds_json_arguments_without_shell_interpolation
    client = RecordingCliClient.new
    client.api(
      service: "sheets",
      resources: %w[spreadsheets values],
      method: "update",
      params: { spreadsheetId: "id; touch /tmp/no", range: "A1" },
      body: { values: [["hello"]] },
    )

    args, = client.args
    assert_equal %w[sheets spreadsheets values update], args.first(4)
    assert_equal "--params", args[4]
    assert_equal({ "spreadsheetId" => "id; touch /tmp/no", "range" => "A1" }, JSON.parse(args[5]))
    assert_equal "--json", args[6]
    assert_equal({ "values" => [["hello"]] }, JSON.parse(args[7]))
  end

  def test_mcp_tool_call_preserves_integration_context
    registry_integration = REGISTRY.fetch("googleworkspace")
    old_client = registry_integration.instance_variable_get(:@client)
    client = RecordingClient.new
    registry_integration.instance_variable_set(:@client, client)
    request = Rack::MockRequest.new(APP)

    response = request.post(
      "/servers/googleworkspace/mcp",
      "HTTP_HOST" => "localhost",
      "HTTP_AUTHORIZATION" => "Bearer static-test-token",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "googleworkspace_drive_file",
          arguments: { file_id: "file-1" },
        },
      ),
    )

    assert_equal 200, response.status
    assert_equal "file-1", client.calls.fetch(0).last.dig(:params, :fileId)
  ensure
    registry_integration.instance_variable_set(:@client, old_client) if registry_integration
  end
end
