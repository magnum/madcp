# frozen_string_literal: true

require "json"

module Madcp
  module Servers
    module GoogleWorkspace
      class Client < CliClient
        FORBIDDEN_ROOT_COMMANDS = %w[
          auth completion config generate-skills mcp schema
        ].freeze
        SEGMENT_PATTERN = /\A[a-zA-Z][a-zA-Z0-9_+-]*\z/

        def initialize
          env = {
            "GOOGLE_WORKSPACE_CLI_TOKEN" => ENV["GOOGLE_WORKSPACE_CLI_TOKEN"],
            "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE" => ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"],
            "GOOGLE_WORKSPACE_CLI_CLIENT_ID" => ENV["GOOGLE_WORKSPACE_CLI_CLIENT_ID"],
            "GOOGLE_WORKSPACE_CLI_CLIENT_SECRET" => ENV["GOOGLE_WORKSPACE_CLI_CLIENT_SECRET"],
            "GOOGLE_WORKSPACE_CLI_CONFIG_DIR" => ENV["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"],
            "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND" => ENV.fetch(
              "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND",
              "file",
            ),
            "GOOGLE_WORKSPACE_PROJECT_ID" => ENV["GOOGLE_WORKSPACE_PROJECT_ID"],
          }.transform_values { |value| value.to_s.strip.empty? ? nil : value }
          super(
            bin: ENV.fetch("GOOGLEWORKSPACE_BIN", "gws"),
            timeout: ENV.fetch("GOOGLEWORKSPACE_TIMEOUT", "60").to_i,
            max_chars: ENV.fetch("MADCP_MAX_CHARS", "100000").to_i,
            env: env,
          )
        end

        def auth_status
          run(%w[auth status], truncate: false)
        end

        def schema(path)
          segments = normalize_segments(path)
          run(["schema", segments.join(".")])
        end

        def help(path = [])
          segments = normalize_segments(path, allow_empty: true)
          run([*segments, "--help"])
        end

        def api(service:, resources:, method:, params: nil, body: nil)
          service_segment = normalize_segments([service]).first
          if FORBIDDEN_ROOT_COMMANDS.include?(service_segment)
            raise CliError, "service '#{service_segment}' is not a Workspace API service"
          end

          resource_segments = normalize_segments(resources)
          method_segment = normalize_segments([method]).first
          args = [service_segment, *resource_segments, method_segment]
          args.push("--params", JSON.generate(params)) if params.is_a?(Hash) && !params.empty?
          args.push("--json", JSON.generate(body)) unless body.nil?
          run(args)
        end

        def helper(service:, helper:, flags:)
          service_segment = normalize_segments([service]).first
          helper_segment = helper.to_s
          unless helper_segment.match?(/\A\+[a-zA-Z][a-zA-Z0-9_-]*\z/)
            raise CliError, "invalid helper name"
          end

          args = [service_segment, helper_segment]
          flags.each do |name, value|
            next if value.nil?

            flag = name.to_s.tr("_", "-")
            raise CliError, "invalid flag name" unless flag.match?(/\A[a-z][a-z0-9-]*\z/)

            args.push("--#{flag}", value.is_a?(String) ? value : JSON.generate(value))
          end
          run(args)
        end

        private

        def normalize_segments(value, allow_empty: false)
          segments = Array(value).flat_map { |item| item.to_s.split(".") }.reject(&:empty?)
          raise CliError, "command path is required" if segments.empty? && !allow_empty
          raise CliError, "invalid command path" unless segments.all? { |segment| segment.match?(SEGMENT_PATTERN) }

          segments
        end
      end
    end
  end
end
