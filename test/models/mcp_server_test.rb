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
    assert_instance_of Madcp::Servers::TeslaMate::Server, server
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

  test "teslamate tool catalog includes reports and run_sql" do
    server = McpServer.fetch!("teslamate")
    names = server.tool_catalog.map { |tool| tool[:name] }
    assert_includes names, "get_battery_capacity_trend"
    assert_includes names, "teslamate_run_sql"
    assert_includes names, "teslamate_get_database_schema"
  end
end
