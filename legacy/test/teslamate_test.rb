# frozen_string_literal: true

require_relative "test_helper"

require "minitest/autorun"
require "tmpdir"
require_relative "../server"

class TeslaMateTest < Minitest::Test
  class FakeClient
    attr_reader :calls

    def initialize(rows: [{ "ok" => 1, "cars" => 2 }], configured: true)
      @rows = rows
      @configured = configured
      @calls = []
      @schema = [
        {
          "table_schema" => "public",
          "table_name" => "cars",
          "column_name" => "id",
          "data_type" => "integer",
          "is_nullable" => "NO",
          "ordinal_position" => 1,
        },
        {
          "table_schema" => "public",
          "table_name" => "cars",
          "column_name" => "name",
          "data_type" => "text",
          "is_nullable" => "YES",
          "ordinal_position" => 2,
        },
      ]
    end

    def configured? = @configured

    def probe
      @calls << [:probe]
      { ok: true, cars: 2 }
    end

    def fetch_all(sql, named = {})
      @calls << [:fetch_all, sql, named]
      @rows
    end

    def fetch_readonly(sql, statement_timeout_ms:)
      @calls << [:fetch_readonly, sql, statement_timeout_ms]
      @rows
    end

    def schema(refresh: false)
      @calls << [:schema, refresh]
      @schema
    end
  end

  def setup
    @old_url = ENV["TESLAMATE_DATABASE_URL"]
    @old_tz = ENV["TESLAMATE_REPORT_TIMEZONE"]
    ENV["TESLAMATE_DATABASE_URL"] = "postgresql://ro:secret@localhost:5432/teslamate"
    ENV["TESLAMATE_REPORT_TIMEZONE"] = "Europe/Rome"
    @integration = Emcp::Servers::TeslaMate::Server.new(config: CONFIG)
    @client = FakeClient.new
    @integration.instance_variable_set(:@client, @client)
  end

  def teardown
    restore_env("TESLAMATE_DATABASE_URL", @old_url)
    restore_env("TESLAMATE_REPORT_TIMEZONE", @old_tz)
  end

  def restore_env(key, value)
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end

  def test_catalog_includes_reports_schema_and_run_sql
    tools = @integration.tool_catalog
    names = tools.map { |tool| tool[:name] }

    assert_equal 32, tools.length
    assert_includes names, "get_battery_capacity_trend"
    assert_includes names, "get_basic_car_information"
    assert_includes names, "teslamate_get_database_schema"
    assert_includes names, "teslamate_run_sql"
    assert tools.none? { |tool| tool[:write] }
  end

  def test_query_registry_loads_bundled_queries
    tools = Emcp::Servers::TeslaMate::QueryRegistry.load(
      File.expand_path("../servers/teslamate/queries", __dir__),
    )
    assert_equal 30, tools.length
    assert tools.all? { |tool| tool.name.start_with?("get_") || tool.name.start_with?("search_") }
  end

  def test_bind_converts_named_placeholders_and_escapes_percent
    sql, values = Emcp::Servers::TeslaMate::QueryRegistry.bind(
      "SELECT %(days)s::int, '%%' AS pct, %(car_name)s::text",
      { "days" => 7, "car_name" => nil },
    )
    assert_equal "SELECT $1::int, '%' AS pct, $2::text", sql
    assert_equal [7, nil], values
  end

  def test_validate_sql_rejects_mutations_and_multi_statements
    Emcp::Servers::TeslaMate::QueryRegistry.validate_sql("SELECT 1")
    Emcp::Servers::TeslaMate::QueryRegistry.validate_sql("WITH x AS (SELECT 1) SELECT * FROM x")

    assert_raises(ArgumentError) do
      Emcp::Servers::TeslaMate::QueryRegistry.validate_sql("INSERT INTO cars VALUES (1)")
    end
    assert_raises(ArgumentError) do
      Emcp::Servers::TeslaMate::QueryRegistry.validate_sql("SELECT 1; SELECT 2")
    end
    assert_raises(ArgumentError) do
      Emcp::Servers::TeslaMate::QueryRegistry.validate_sql("SELECT 1; DROP TABLE cars")
    end
  end

  def test_enforce_limit_wraps_when_missing
    capped = Emcp::Servers::TeslaMate::QueryRegistry.enforce_limit("SELECT * FROM cars", 50)
    assert_equal "SELECT * FROM (SELECT * FROM cars) AS _capped LIMIT 50", capped

    already = Emcp::Servers::TeslaMate::QueryRegistry.enforce_limit("SELECT * FROM cars LIMIT 3", 50)
    assert_equal "SELECT * FROM cars LIMIT 3", already
  end

  def test_predefined_tool_injects_timezone
    @integration.call_tool("get_battery_capacity_trend", days: 30, min_soc_delta: 15)

    method, sql, named = @client.calls.fetch(0)
    assert_equal :fetch_all, method
    assert_includes sql, "charging_processes"
    assert_equal "Europe/Rome", named["tz"]
    assert_equal 30, named["days"]
    assert_equal 15, named["min_soc_delta"]
  end

  def test_run_sql_validates_and_uses_readonly_path
    @integration.call_tool("teslamate_run_sql", query: "SELECT id FROM cars")

    method, sql, timeout = @client.calls.fetch(0)
    assert_equal :fetch_readonly, method
    assert_includes sql, "_capped"
    assert_equal 5000, timeout
  end

  def test_schema_tool_summary_and_detail
    summary = JSON.parse(@integration.call_tool("teslamate_get_database_schema", {}).content.first[:text])
    assert_equal [{ "table_schema" => "public", "table_name" => "cars", "column_count" => 2 }], summary

    detail = JSON.parse(
      @integration.call_tool("teslamate_get_database_schema", table: "cars").content.first[:text],
    )
    assert_equal 2, detail.length
    assert_equal "id", detail.fetch(0).fetch("column_name")
  end

  def test_auth_status_uses_probe
    status = @integration.auth_status(force: true)
    assert_equal true, status[:authenticated]
    assert_equal 2, status[:cars]
    assert_equal :probe, @client.calls.fetch(0).fetch(0)
  end

  def test_fixture_registry_pair
    Dir.mktmpdir("teslamate-queries") do |dir|
      File.write(File.join(dir, "sample.sql"), "SELECT %(days)s::int AS d;\n")
      File.write(
        File.join(dir, "sample.toml"),
        <<~TOML,
          name = "get_sample"
          description = "Fixture report"

          [[params]]
          name = "days"
          type = "integer"
          description = "Lookback days"
          default = 7
        TOML
      )
      tools = Emcp::Servers::TeslaMate::QueryRegistry.load(dir)
      assert_equal 1, tools.length
      assert_equal "get_sample", tools.first.name
      assert_equal false, tools.first.uses_tz
    end
  end
end
