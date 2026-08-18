# frozen_string_literal: true

module Madcp
  module Servers
    module HomeAssistant
      class Client < CliClient
        def initialize
          super(
            bin: ENV.fetch("HASS_CLI_BIN", "hass-cli"),
            timeout: ENV.fetch("HASS_TIMEOUT", "30").to_i,
            max_chars: ENV.fetch("MADCP_MAX_CHARS", "100000").to_i,
            env: {
              "HASS_SERVER" => ENV.fetch("HASS_SERVER", ""),
              "HASS_TOKEN" => ENV.fetch("HASS_TOKEN", ""),
            },
          )
        end

        # Global flags must precede the subcommand (Click).
        def json(*parts)
          args = ["--output=json", *parts]
          args.unshift("--insecure") if insecure?
          args
        end

        def config_release = json("config", "release")
        def info = json("info")
        def state_list(filter = nil) = json("state", "list", *[filter].compact)
        def state_get(entity_id) = json("state", "get", entity_id)
        def state_history(entity_ids, since: nil)
          parts = ["state", "history"]
          parts.push("--since", since.to_s) if since.present?
          parts.concat(Array(entity_ids))
          json(*parts)
        end

        def state_edit(entity_id, json_body:)
          json("state", "edit", entity_id, "--json=#{json_body}")
        end

        def service_list(filter = nil) = json("service", "list", *[filter].compact)
        def service_call(service, arguments: nil)
          parts = ["service", "call", service]
          parts.push("--arguments", arguments.to_s) if arguments.present?
          json(*parts)
        end

        def device_list(filter = nil) = json("device", "list", *[filter].compact)
        def area_list(filter = nil) = json("area", "list", *[filter].compact)
        def area_create(name) = json("area", "create", name)
        def area_delete(name) = json("area", "delete", name)
        def device_assign(area, *devices, match: nil)
          parts = ["device", "assign", area, *devices]
          parts.push("--match", match.to_s) if match.present?
          json(*parts)
        end

        def entity_list(filter = nil) = json("entity", "list", *[filter].compact)
        def raw(method, path, data: nil)
          json("raw", method, path).tap do |args|
            args.push("--data", data) if data.present?
          end
        end

        private

        def insecure?
          ActiveModel::Type::Boolean.new.cast(ENV.fetch("HASS_INSECURE", "false"))
        end
      end
    end
  end
end
