# frozen_string_literal: true

require "test_helper"

class McpServerTest < ActiveSupport::TestCase
  setup do
    McpServer.discover!
  end

  test "discovers registered integrations" do
    codes = McpServer.order(:code).pluck(:code)
    assert_includes codes, "hey"
    assert_includes codes, "teslamate"
    assert_includes codes, "toggltrack"
  end

  test "sti fetch returns concrete class" do
    server = McpServer.fetch!("teslamate")
    assert_instance_of Emcp::Servers::TeslaMate::Server, server
  end

  test "token_refresh_in_minutes blank disables scheduled refresh" do
    server = McpServer.fetch!("hey")
    server.update!(token_refresh_in_minutes: "")
    assert_nil server.reload.token_refresh_in_minutes
    refute server.token_refresh_enabled?

    server.update!(token_refresh_in_minutes: 60)
    assert_equal 60, server.token_refresh_in_minutes
    assert server.token_refresh_enabled?
  end

  test "service_token_refresh_in_minutes blank disables provider refresh schedule" do
    server = McpServer.fetch!("hey")
    server.update!(service_token_refresh_in_minutes: "")
    assert_nil server.reload.service_token_refresh_in_minutes
    refute server.service_token_refresh_enabled?

    server.update!(service_token_refresh_in_minutes: 90)
    assert_equal 90, server.service_token_refresh_in_minutes
    assert server.service_token_refresh_enabled?
  end

  test "provider defaults for service_token_refresh_in_minutes" do
    assert_equal 1_440, Emcp::Servers::GoogleWorkspace::Server.default_service_token_refresh_in_minutes
    assert_equal 1_320, Emcp::Servers::FattureInCloud::Server.default_service_token_refresh_in_minutes
    assert_equal 90, Emcp::Servers::Twitter::Server.default_service_token_refresh_in_minutes
    assert_equal 90, Emcp::Servers::Bluesky::Server.default_service_token_refresh_in_minutes
    assert_nil Emcp::Servers::Hey::Server.default_service_token_refresh_in_minutes
    assert_equal 10_080, Emcp::Servers::Basecamp::Server.default_service_token_refresh_in_minutes
  end

  test "teslamate tool catalog includes reports and run_sql" do
    server = McpServer.fetch!("teslamate")
    names = server.tool_catalog.map { |tool| tool[:name] }
    assert_includes names, "get_battery_capacity_trend"
    assert_includes names, "teslamate_run_sql"
    assert_includes names, "teslamate_get_database_schema"
  end

  test "registered servers implement the runtime contract" do
    McpServer.integration_classes.each do |klass|
      server = McpServer.fetch!(klass.server_id)
      assert server.instance_variable_get(:@client),
        "#{klass.server_id} must implement replace_client!"
      assert_kind_of Array, server.credential_env_keys
    end
  end

  test "unimplemented contract methods raise NotImplementedError" do
    server = Class.new(McpServer).allocate

    assert_raises(NotImplementedError) { server.configure_tools }
    assert_raises(NotImplementedError) { server.apply_credentials({}) }
    assert_raises(NotImplementedError) { server.clear_credentials! }
    assert_raises(NotImplementedError) { server.fetch_auth_status }
    assert_raises(NotImplementedError) { server.replace_client! }
    assert_raises(NotImplementedError) { server.credential_env_keys }
    assert_raises(NotImplementedError) { server.oauth_call(callback_url: "/", state: "s") }
    assert_raises(NotImplementedError) { server.oauth_exchange(callback_url: "/", params: {}) }
  end
end
