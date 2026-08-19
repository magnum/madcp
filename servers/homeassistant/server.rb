# frozen_string_literal: true

require_relative "homeassistant_client"

module Emcp
  module Servers
    module HomeAssistant
      class Server < ::McpServer
        server_id "homeassistant"
        display_name "Home Assistant"
        description "States, services, devices, and areas through the Home Assistant CLI (hass-cli)."
        version "0.1.0"

        def instructions
          "Use Home Assistant tools to inspect and control a Home Assistant instance via hass-cli. " \
            "Requires HASS_SERVER and HASS_TOKEN (long-lived access token). " \
            "Write tools (service call, state edit, area/device changes) stay disabled unless " \
            "HOMEASSISTANT_ALLOW_WRITE=true. Prefer entity_id values from hass_state_list / hass_state_get."
        end

        def auth_help_content
          {
            title: "Connect Home Assistant",
            description: "EmCP drives the official hass-cli against your HA instance using " \
                         "HASS_SERVER and a long-lived access token (HASS_TOKEN).",
            steps: [
              "In Home Assistant open your profile → Long-Lived Access Tokens → Create Token.",
              "Set the server URL (e.g. http://homeassistant.local:8123 or https://ha.example.com).",
              "Paste server URL and token below (or set HASS_SERVER / HASS_TOKEN in the host .env).",
              "Optional: set HASS_INSECURE=true if HA uses a self-signed TLS certificate.",
            ],
            commands: [
              {
                label: "Probe config release",
                value: 'hass-cli --output=json config release',
              },
              {
                label: "List a few states",
                value: 'hass-cli --output=json state list light',
              },
            ],
            note: "Treat HASS_TOKEN as a password. Write operations need HOMEASSISTANT_ALLOW_WRITE=true.",
          }
        end

        def auth_fields
          [
            {
              name: "hass_server",
              label: "Home Assistant server URL",
              type: "text",
              required: true,
              help: "Example: http://192.168.0.10:8123 — stored as HASS_SERVER.",
              env: "HASS_SERVER",
            },
            {
              name: "hass_token",
              label: "Long-lived access token",
              type: "password",
              required: true,
              help: "From HA profile → Long-Lived Access Tokens. Leave blank to keep a saved token.",
              env: "HASS_TOKEN",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def fetch_auth_status
          load_credentials!
          raw = @client.run(@client.config_release, truncate: false)
          version = parse_release_version(raw)
          {
            authenticated: true,
            server: Emcp.sanitize_env_value(ENV["HASS_SERVER"]),
            version: version,
          }
        rescue StandardError => e
          {
            authenticated: false,
            server: Emcp.sanitize_env_value(ENV["HASS_SERVER"]),
            error: e.message,
          }
        end

        def apply_credentials(params)
          load_credentials!
          server = Emcp.sanitize_env_value(params["hass_server"])
          token = Emcp.sanitize_env_value(params["hass_token"])

          updates = {}
          updates["HASS_SERVER"] = server if server.present?
          updates["HASS_TOKEN"] = token if token.present?

          effective_server = updates["HASS_SERVER"].presence ||
            Emcp.sanitize_env_value(ENV["HASS_SERVER"])
          effective_token = updates["HASS_TOKEN"].presence ||
            Emcp.sanitize_env_value(ENV["HASS_TOKEN"])

          raise "HASS_SERVER is required" if effective_server.empty?
          raise "HASS_TOKEN is required" if effective_token.empty?

          apply_credentials_probe!(
            {
              "HASS_SERVER" => effective_server,
              "HASS_TOKEN" => effective_token,
            },
            rejection_message: "Home Assistant server URL or token was rejected",
          )
        ensure
          token = nil
        end

        def clear_credentials!
          persist_credentials!("HASS_SERVER" => nil, "HASS_TOKEN" => nil)
          replace_client!
        end

        def configure_tools
          define_info_tools
          define_state_tools
          define_service_tools
          define_registry_tools
          define_raw_tool
        end

        def replace_client!
          @client = Client.new
        end

        def credential_env_keys = %w[HASS_SERVER HASS_TOKEN]

        private

        def parse_release_version(raw)
          data = JSON.parse(raw)
          case data
          when Array then data.first
          when Hash then data["version"] || data["VERSION"] || data.values.first
          else data
          end
        rescue JSON::ParserError
          raw.to_s.lines.map(&:strip).reject(&:empty?).last
        end

        def define_info_tools
          define_tool(
            name: "hass_config_release",
            description: "Return the Home Assistant Core version (hass-cli config release).",
          ) { cli_response(@client, @client.config_release) }

          define_tool(
            name: "hass_info",
            description: "Show hass-cli / connection information.",
          ) { cli_response(@client, @client.info) }
        end

        def define_state_tools
          define_tool(
            name: "hass_state_list",
            description: "List entity states. Optional filter is a substring/regex passed to hass-cli.",
            properties: {
              filter: string_prop("Optional entity filter (e.g. light, sensor.temperature)"),
            },
          ) { |filter: nil| cli_response(@client, @client.state_list(filter)) }

          define_tool(
            name: "hass_state_get",
            description: "Get the full state object for one entity_id.",
            properties: { entity_id: string_prop("Entity ID, e.g. light.kitchen") },
            required: ["entity_id"],
          ) { |entity_id:| cli_response(@client, @client.state_get(entity_id)) }

          define_tool(
            name: "hass_state_history",
            description: "History for one or more entities (optional --since, e.g. 50m, 2h).",
            properties: {
              entity_ids: {
                type: "array",
                items: { type: "string" },
                description: "Entity IDs to query",
              },
              since: string_prop("Relative window, e.g. 50m or 2h"),
            },
            required: ["entity_ids"],
          ) do |entity_ids:, since: nil|
            ids = Array(entity_ids).map(&:to_s).reject(&:empty?)
            raise "entity_ids is required" if ids.empty?

            cli_response(@client, @client.state_history(ids, since: since))
          end

          define_tool(
            name: "hass_state_edit",
            description: "Create/update an entity state with a JSON body (write).",
            properties: {
              entity_id: string_prop("Entity ID"),
              json: string_prop('JSON object string, e.g. {"state":"on"}'),
            },
            required: %w[entity_id json],
            write: true,
          ) { |entity_id:, json:| cli_response(@client, @client.state_edit(entity_id, json_body: json)) }
        end

        def define_service_tools
          define_tool(
            name: "hass_service_list",
            description: "List available services. Optional filter regex/substring.",
            properties: { filter: string_prop("Optional filter, e.g. light.turn_on or home.*toggle") },
          ) { |filter: nil| cli_response(@client, @client.service_list(filter)) }

          define_tool(
            name: "hass_service_call",
            description: "Call a Home Assistant service (write). Arguments use hass-cli --arguments form " \
                         "(e.g. entity_id=light.office).",
            properties: {
              service: string_prop("domain.service, e.g. light.turn_on or homeassistant.toggle"),
              arguments: string_prop("Optional key=value[,key=value] for --arguments"),
            },
            required: ["service"],
            write: true,
          ) { |service:, arguments: nil| cli_response(@client, @client.service_call(service, arguments: arguments)) }
        end

        def define_registry_tools
          define_tool(
            name: "hass_device_list",
            description: "List devices from the device registry.",
            properties: { filter: string_prop("Optional name/id filter") },
          ) { |filter: nil| cli_response(@client, @client.device_list(filter)) }

          define_tool(
            name: "hass_area_list",
            description: "List areas.",
            properties: { filter: string_prop("Optional name/id filter") },
          ) { |filter: nil| cli_response(@client, @client.area_list(filter)) }

          define_tool(
            name: "hass_entity_list",
            description: "List entities from the entity registry.",
            properties: { filter: string_prop("Optional filter") },
          ) { |filter: nil| cli_response(@client, @client.entity_list(filter)) }

          define_tool(
            name: "hass_area_create",
            description: "Create an area (write).",
            properties: { name: string_prop("Area name") },
            required: ["name"],
            write: true,
          ) { |name:| cli_response(@client, @client.area_create(name)) }

          define_tool(
            name: "hass_area_delete",
            description: "Delete an area by name (write).",
            properties: { name: string_prop("Area name") },
            required: ["name"],
            write: true,
          ) { |name:| cli_response(@client, @client.area_delete(name)) }

          define_tool(
            name: "hass_device_assign",
            description: "Assign an area to devices (write). Pass device names/ids and/or a --match substring.",
            properties: {
              area: string_prop("Area name or id"),
              devices: {
                type: "array",
                items: { type: "string" },
                description: "Optional device names or ids",
              },
              match: string_prop("Optional substring match for device names"),
            },
            required: ["area"],
            write: true,
          ) do |area:, devices: nil, match: nil|
            list = Array(devices).map(&:to_s).reject(&:empty?)
            cli_response(@client, @client.device_assign(area, *list, match: match))
          end
        end

        def define_raw_tool
          define_tool(
            name: "hass_raw",
            description: "Advanced: call the Home Assistant REST API via hass-cli raw. " \
                         "Non-GET methods require HOMEASSISTANT_ALLOW_WRITE=true.",
            properties: {
              method: string_prop("HTTP method, e.g. get or post"),
              path: string_prop("API path, e.g. /api/states"),
              data: string_prop("Optional JSON body for write methods"),
            },
            required: %w[method path],
          ) do |method:, path:, data: nil|
            verb = method.to_s.downcase
            unless %w[get head options].include?(verb) || allow_write_methods?
              raise SecurityError, "write method disabled"
            end

            cli_response(@client, @client.raw(verb, path, data: data))
          end
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::HomeAssistant::Server)
