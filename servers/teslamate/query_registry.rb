# frozen_string_literal: true

require "pathname"
require "toml-rb"

module Madcp
  module Servers
    module TeslaMate
      ToolParam = Data.define(:name, :type, :description, :required, :default, :minimum, :maximum, :enum)
      PredefinedTool = Data.define(:name, :description, :sql, :source, :params, :uses_tz)

      # Discovers .sql + .toml query pairs and converts psycopg-style %(name)s
      # placeholders into PostgreSQL $n binds for the `pg` gem.
      class QueryRegistry
        PLACEHOLDER_RE = /%\((\w+)\)s/
        PARAM_NAME_RE = /\A[a-z][a-z0-9_]{0,29}\z/
        RESERVED_PARAM_NAMES = %w[ctx tz].freeze
        ALLOWED_TYPES = %w[string integer number boolean].freeze

        class << self
          def load(directory)
            dir = Pathname(directory)
            raise ArgumentError, "queries directory missing: #{dir}" unless dir.directory?

            dir.glob("*.sql").sort.map { |sql_path| load_pair(sql_path) }
          end

          # Returns [sql_with_$n, positional_values]
          def bind(sql, named)
            named = stringify_keys(named)
            values = []
            out = +""
            i = 0
            while i < sql.length
              ch = sql[i]
              if ch == "%" && sql[i + 1] == "%"
                out << "%"
                i += 2
              elsif ch == "%" && sql[i + 1] == "("
                close = sql.index(")s", i + 2)
                raise ArgumentError, "invalid placeholder near index #{i}" unless close

                name = sql[(i + 2)...close]
                values << named[name]
                out << "$#{values.length}"
                i = close + 2
              else
                out << ch
                i += 1
              end
            end
            [out, values]
          end

          def validate_sql(sql)
            stripped = sql.to_s.strip
            raise ArgumentError, "Query is empty" if stripped.empty?

            clean = strip_safe(stripped).strip
            raise ArgumentError, "Query contains no executable statement" if clean.empty?

            body = clean.rstrip.sub(/;\z/, "")
            raise ArgumentError, "Multiple SQL statements are not allowed" if body.include?(";")

            first = body[/\A\s*([A-Za-z]+)/, 1]&.upcase
            raise ArgumentError, "Query must start with SELECT or WITH" unless %w[SELECT WITH].include?(first)
            raise ArgumentError, "Query contains a forbidden keyword" if forbidden_keyword?(body)

            nil
          end

          def enforce_limit(sql, default_limit)
            body = sql.strip.sub(/;\z/, "").rstrip
            return body if body.match?(/\bLIMIT\b\s+\d+/i)

            "SELECT * FROM (#{body}) AS _capped LIMIT #{Integer(default_limit)}"
          end

          private

          def load_pair(sql_path)
            toml_path = sql_path.sub_ext(".toml")
            raise Errno::ENOENT, "Missing sidecar for #{sql_path.basename}: #{toml_path.basename}" unless toml_path.file?

            meta = TomlRB.load_file(toml_path.to_s)
            name = meta.fetch("name")
            description = meta.fetch("description")
            raw_params = meta["params"] || []
            raise ArgumentError, "#{toml_path.basename}: 'params' must be an array" unless raw_params.is_a?(Array)

            params = raw_params.map { |raw| parse_param(raw, toml_path.basename.to_s) }
            seen = {}
            params.each do |param|
              raise ArgumentError, "#{toml_path.basename}: duplicate param #{param.name.inspect}" if seen[param.name]

              seen[param.name] = true
            end

            sql = sql_path.read
            uses_tz = validate_placeholders!(sql, params, toml_path.basename.to_s)
            PredefinedTool.new(
              name: name,
              description: description,
              sql: sql,
              source: sql_path.basename.to_s,
              params: params.freeze,
              uses_tz: uses_tz,
            )
          end

          def parse_param(raw, source)
            raise ArgumentError, "#{source}: each [[params]] entry must be a table" unless raw.is_a?(Hash)

            name = raw.fetch("name")
            type = raw.fetch("type")
            description = raw.fetch("description")
            unless name.is_a?(String) && PARAM_NAME_RE.match?(name)
              raise ArgumentError, "#{source}: invalid param name #{name.inspect}"
            end
            raise ArgumentError, "#{source}: param name #{name.inspect} is reserved" if RESERVED_PARAM_NAMES.include?(name)
            raise ArgumentError, "#{source}: unsupported param type #{type.inspect}" unless ALLOWED_TYPES.include?(type)

            ToolParam.new(
              name: name,
              type: type,
              description: description.to_s,
              required: !!raw["required"],
              default: raw.key?("default") ? raw["default"] : nil,
              minimum: raw["minimum"],
              maximum: raw["maximum"],
              enum: raw["enum"]&.map(&:to_s),
            )
          end

          def validate_placeholders!(sql, params, source)
            placeholders = sql.scan(PLACEHOLDER_RE).flatten.uniq
            uses_tz = placeholders.include?("tz")
            declared = params.map(&:name)
            undeclared = placeholders - ["tz"] - declared
            unless undeclared.empty?
              raise ArgumentError, "#{source}: SQL placeholder(s) #{undeclared.sort.inspect} are not declared"
            end

            unused = declared - placeholders
            unless unused.empty?
              raise ArgumentError, "#{source}: declared param(s) #{unused.sort.inspect} are not used in the SQL"
            end

            if (params.any? || uses_tz) && sql.match?(/(?<!%)%(?![%(])/)
              raise ArgumentError, "#{source}: bare '%' must be escaped as '%%' in parameterized SQL"
            end

            uses_tz
          end

          def stringify_keys(values)
            values.to_h.transform_keys(&:to_s)
          end

          def strip_safe(sql)
            s = sql.gsub(%r{/\*.*?\*/}m, "")
            s = s.gsub(/--.*$/, "")
            s = s.gsub(/'(?:''|[^'])*'/, "''")
            s.gsub(/"(?:""|[^"])*"/, '""')
          end

          FORBIDDEN = /\b(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|GRANT|REVOKE|COPY|VACUUM|CLUSTER|REINDEX|REFRESH|CALL|DO|EXECUTE|LISTEN|NOTIFY|LOCK|SECURITY|RESET|DISCARD|CHECKPOINT)\b/i

          def forbidden_keyword?(body)
            FORBIDDEN.match?(body)
          end
        end
      end
    end
  end
end
