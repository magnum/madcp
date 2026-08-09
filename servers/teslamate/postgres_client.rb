# frozen_string_literal: true

require "bigdecimal"
require "json"
require "pg"

module Madcp
  module Servers
    module TeslaMate
      class PostgresClient
        SCHEMA_QUERY = <<~SQL.freeze
          SELECT
              table_schema,
              table_name,
              column_name,
              data_type,
              is_nullable,
              ordinal_position
          FROM information_schema.columns
          WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
            AND table_schema NOT LIKE 'pg_%'
          ORDER BY table_schema, table_name, ordinal_position
        SQL

        def initialize(database_url: nil, statement_timeout_ms: nil)
          @database_url = database_url
          @statement_timeout_ms = Integer(statement_timeout_ms || ENV.fetch("TESLAMATE_STATEMENT_TIMEOUT_MS", "30000"))
          @schema_cache = nil
        end

        def configured?
          !database_url.empty?
        end

        def probe
          rows = fetch_all("SELECT 1 AS ok, (SELECT count(*)::int FROM cars) AS cars")
          row = rows.first || {}
          { ok: true, cars: row["cars"] }
        end

        def fetch_all(sql, named = {})
          bound_sql, values = QueryRegistry.bind(sql, named)
          with_connection do |conn|
            apply_statement_timeout!(conn, @statement_timeout_ms)
            exec_rows(conn, bound_sql, values)
          end
        end

        def fetch_readonly(sql, statement_timeout_ms:)
          timeout = Integer(statement_timeout_ms)
          with_connection do |conn|
            conn.exec("BEGIN READ ONLY")
            begin
              conn.exec("SET LOCAL statement_timeout = #{timeout}")
              conn.exec("SET LOCAL lock_timeout = 2000")
              conn.exec("SET LOCAL idle_in_transaction_session_timeout = #{timeout}")
              rows = exec_rows(conn, sql, [])
              conn.exec("ROLLBACK")
              rows
            rescue StandardError
              begin
                conn.exec("ROLLBACK")
              rescue StandardError
                # ignore rollback errors
              end
              raise
            end
          end
        end

        def schema(refresh: false)
          @schema_cache = nil if refresh
          @schema_cache ||= fetch_all(SCHEMA_QUERY)
        end

        def close
          # Connections are opened per call; nothing to close.
        end

        private

        def database_url
          Madcp.sanitize_env_value(@database_url || ENV["TESLAMATE_DATABASE_URL"])
        end

        def with_connection
          raise "TESLAMATE_DATABASE_URL is not configured" unless configured?

          conn = PG.connect(database_url)
          begin
            yield conn
          ensure
            conn.close
          end
        end

        def apply_statement_timeout!(conn, ms)
          conn.exec("SET statement_timeout = #{Integer(ms)}")
        end

        def exec_rows(conn, sql, values)
          result = values.empty? ? conn.exec(sql) : conn.exec_params(sql, values)
          result.map { |row| jsonable_row(row) }
        ensure
          result&.clear
        end

        def jsonable_row(row)
          row.each_with_object({}) do |(key, value), acc|
            acc[key] = jsonable_value(value)
          end
        end

        def jsonable_value(value)
          case value
          when nil, true, false, Integer, Float, String
            value
          when BigDecimal
            value.to_s("F")
          else
            value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
          end
        end
      end
    end
  end
end
