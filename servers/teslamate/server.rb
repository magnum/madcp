# frozen_string_literal: true

require "pathname"
require_relative "query_registry"
require_relative "postgres_client"

module Madcp
  module Servers
    module TeslaMate
      class Server < ::McpServer
        server_id "teslamate"
        display_name "TeslaMate"
        description "Read TeslaMate PostgreSQL analytics: drives, charging, battery health, and custom SQL."
        version "0.1.0"

        QUERIES_DIR = File.expand_path("queries", __dir__)
        after_initialize :ensure_runtime_client
        after_find :ensure_runtime_client

        def ensure_runtime_client
          return if defined?(@client) && @client
          replace_client! if respond_to?(:replace_client!, true)
        end

        def instructions
          "Use TeslaMate tools to query vehicle analytics from the TeslaMate database. " \
            "Predefined reports accept optional filters (car_name, days, limit). " \
            "Call teslamate_get_database_schema before teslamate_run_sql for ad-hoc SELECT queries. " \
            "All tools are read-only."
        end

        def auth_help_content
          {
            title: "Connect TeslaMate PostgreSQL",
            description: "MadCP connects directly to your TeslaMate Postgres database " \
                         "(same approach as teslamate-mcp). Prefer a dedicated read-only role.",
            steps: [
              "Create a read-only PostgreSQL role with SELECT on TeslaMate tables.",
              "Paste a connection URI as TESLAMATE_DATABASE_URL " \
              "(postgresql://user:pass@host:5432/teslamate).",
              "Keep the database on a private network (VPN / Tailscale); do not expose it publicly.",
            ],
            commands: [
              {
                label: "Probe connectivity",
                value: 'psql "$TESLAMATE_DATABASE_URL" -c "SELECT count(*) FROM cars"',
              },
            ],
            note: "Do not use TeslaMate's Compose superuser for MadCP. " \
                  "A read-only role limits blast radius if the URL leaks.",
          }
        end

        def auth_fields
          [
            {
              name: "teslamate_database_url",
              label: "PostgreSQL connection URL",
              type: "password",
              required: false,
              help: "postgresql://user:password@host:5432/teslamate (read-only role recommended)",
              env: "TESLAMATE_DATABASE_URL",
            },
            {
              name: "teslamate_report_timezone",
              label: "Report timezone (optional)",
              type: "text",
              required: false,
              help: "IANA timezone for daily/monthly buckets (default UTC).",
              env: "TESLAMATE_REPORT_TIMEZONE",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def fetch_auth_status
          load_credentials!
          unless @client.configured?
            return {
              authenticated: false,
              error: "TESLAMATE_DATABASE_URL is not configured",
            }
          end

          probe = @client.probe
          {
            authenticated: true,
            source: "postgresql",
            cars: probe[:cars],
          }
        rescue StandardError => e
          {
            authenticated: false,
            error: e.message,
          }
        end

        def apply_credentials(params)
          url = Madcp.sanitize_env_value(params["teslamate_database_url"])
          tz = Madcp.sanitize_env_value(params["teslamate_report_timezone"])
          apply_credentials_probe!(
            {
              "TESLAMATE_DATABASE_URL" => url,
              "TESLAMATE_REPORT_TIMEZONE" => tz,
            },
            rejection_message: "TeslaMate database URL was rejected",
          )
        end

        def clear_credentials!
          persist_credentials!(
            "TESLAMATE_DATABASE_URL" => nil,
            "TESLAMATE_REPORT_TIMEZONE" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_predefined_tools
          define_schema_tool
          define_run_sql_tool
        end

        protected

        def credential_env_keys
          %w[
            TESLAMATE_DATABASE_URL
            TESLAMATE_REPORT_TIMEZONE
          ]
        end

        def replace_client!
          @client = build_client
          @predefined = QueryRegistry.load(QUERIES_DIR)
        end

        private

        def build_client
          PostgresClient.new
        end

        def report_timezone
          tz = Madcp.sanitize_env_value(ENV["TESLAMATE_REPORT_TIMEZONE"])
          tz.empty? ? "UTC" : tz
        end

        def query_timeout_ms
          Integer(ENV.fetch("TESLAMATE_QUERY_TIMEOUT_MS", "5000"))
        end

        def custom_sql_row_limit
          Integer(ENV.fetch("TESLAMATE_CUSTOM_SQL_ROW_LIMIT", "1000"))
        end

        def define_predefined_tools
          @predefined.each do |tool|
            properties = {}
            required = []
            tool.params.each do |param|
              properties[param.name] = param_property(param)
              required << param.name if param.required
            end

            define_tool(
              name: tool.name,
              description: tool.description,
              properties: properties,
              required: required,
            ) do |**args|
              bound = tool.params.each_with_object({}) do |param, acc|
                key = param.name.to_sym
                value = args.key?(key) ? args[key] : param.default
                value = nil if value == ""
                acc[param.name] = value
              end
              bound["tz"] = report_timezone if tool.uses_tz
              api_response(@client.fetch_all(tool.sql, bound))
            end
          end
        end

        def define_schema_tool
          define_tool(
            name: "teslamate_get_database_schema",
            description: "Explore the TeslaMate database schema. Without arguments: a compact " \
                         "list of every table with its column count. With table: full column " \
                         "detail for that table. Pass refresh=true to re-read after DDL changes.",
            properties: {
              table: string_prop("Table name for full column detail. Omit for a compact list of all tables."),
              refresh: boolean_prop("Re-read the schema from the database instead of the cached copy."),
            },
          ) do |table: nil, refresh: false|
            rows = @client.schema(refresh: !!refresh)
            if table.to_s.strip.empty?
              counts = Hash.new(0)
              order = []
              rows.each do |row|
                key = [row["table_schema"], row["table_name"]]
                order << key unless counts.key?(key)
                counts[key] += 1
              end
              summary = order.map do |(schema, name)|
                { "table_schema" => schema, "table_name" => name, "column_count" => counts[[schema, name]] }
              end
              api_response(summary)
            else
              wanted = table.to_s.downcase
              detail = rows.select { |row| row["table_name"].to_s.downcase == wanted }
              raise "Unknown table #{table.inspect}. Call teslamate_get_database_schema without arguments." if detail.empty?

              api_response(detail)
            end
          end
        end

        def define_run_sql_tool
          define_tool(
            name: "teslamate_run_sql",
            description: "Execute a custom read-only SQL query against the TeslaMate database. " \
                         "Only SELECT (and WITH ... SELECT) statements are accepted. The query " \
                         "runs in a READ ONLY transaction with statement_timeout enforced; if " \
                         "no LIMIT is supplied, the result is automatically capped. Call " \
                         "teslamate_get_database_schema first to learn available tables.",
            properties: {
              query: string_prop("A single SELECT or WITH...SELECT statement."),
            },
            required: ["query"],
          ) do |query:|
            QueryRegistry.validate_sql(query)
            capped = QueryRegistry.enforce_limit(query, custom_sql_row_limit)
            api_response(@client.fetch_readonly(capped, statement_timeout_ms: query_timeout_ms))
          end
        end

        def param_property(param)
          base =
            case param.type
            when "integer" then integer_prop(param.description)
            when "number" then { type: "number", description: param.description }
            when "boolean" then boolean_prop(param.description)
            else string_prop(param.description)
            end
          base = base.merge("minimum" => param.minimum) unless param.minimum.nil?
          base = base.merge("maximum" => param.maximum) unless param.maximum.nil?
          base = base.merge("enum" => param.enum) if param.enum
          unless param.required || param.default.nil?
            base = base.merge("default" => param.default)
          end
          base
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::TeslaMate::Server)
