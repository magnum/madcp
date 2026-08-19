# frozen_string_literal: true

module Emcp
  module Servers
    module Basecamp
      class Client < CliClient
        def initialize(env: {})
          super(
            bin: ENV.fetch("BASECAMP_BIN", "basecamp"),
            timeout: ENV.fetch("BASECAMP_TIMEOUT", "30").to_i,
            max_chars: ENV.fetch("EMCP_MAX_CHARS", "100000").to_i,
            env: env,
          )
        end

        def json(*parts) = [*parts, "--json"]

        def command(*parts, project: nil, limit: nil, fetch_all: false, options: {}, flags: [])
          args = json(*parts)
          options.each { |flag, value| args.push(flag.to_s, value.to_s) unless value.nil? || value == "" }
          flags.each { |flag, enabled| args << flag.to_s if enabled }
          args.push("--in", project.to_s) if project && project != ""
          if fetch_all
            args << "--all"
          elsif limit
            args.push("--limit", limit.to_i.clamp(1, 500).to_s)
          end
          args
        end

        def auth_status = json("auth", "status")
        def auth_token = ["auth", "token", "--quiet"]
        def auth_logout = json("auth", "logout")
        def doctor = json("doctor")
        def config_show = json("config", "show")
        def me = json("me")
      end
    end
  end
end
