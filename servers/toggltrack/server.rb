# frozen_string_literal: true

require_relative "toggltrack_client"

module Emcp
  module Servers
    module TogglTrack
      class Server < ::McpServer
        server_id "toggltrack"
        display_name "Toggl Track"
        description "Time entries, projects, tags, organizations, and workspaces through the Toggl Track API v9."
        version "0.1.0"
        after_initialize :ensure_runtime_client
        after_find :ensure_runtime_client

        def ensure_runtime_client
          return if defined?(@client) && @client
          replace_client! if respond_to?(:replace_client!, true)
        end

        def instructions
          "Use Toggl Track tools to inspect and manage time tracking data. " \
            "Workspace-scoped tools fall back to TOGGLTRACK_WORKSPACE_ID when workspace_id is omitted. " \
            "Write tools remain disabled unless TOGGLTRACK_ALLOW_WRITE=true."
        end

        def auth_help_content
          {
            title: "Authorize Toggl Track",
            description: "EmCP uses your personal Toggl Track API token with HTTP Basic Auth " \
                         "(token as username and api_token as password), as documented by Toggl Engineering.",
            steps: [
              "Open Toggl Track Profile settings and copy your API token.",
              "Copy the Organization ID and Workspace ID you use from your JS client.",
              "Paste token, organization ID, and workspace ID into this form.",
            ],
            commands: [
              {
                label: "Verify the token against the configured workspace (preferred; uses workspace quota)",
                value: 'curl -u "$TOGGLTRACK_TOKEN:api_token" ' \
                       '"https://api.track.toggl.com/api/v9/workspaces/$TOGGLTRACK_WORKSPACE_ID"',
              },
              {
                label: "Fallback user probe (scarce /me quota — 30 req/hour)",
                value: 'curl -u "$TOGGLTRACK_TOKEN:api_token" https://api.track.toggl.com/api/v9/me',
              },
            ],
            note: "Organization ID and workspace ID are stored as defaults for workspace-scoped tools. " \
                  "Auth status prefers a workspace probe when TOGGLTRACK_WORKSPACE_ID is set. " \
                  "Treat the API token as a password and paste it only over HTTPS.",
          }
        end

        def auth_fields
          [
            {
              name: "toggltrack_token",
              label: "Toggl Track API token",
              type: "password",
              required: false,
              help: "Personal API token from Toggl Track profile settings.",
              env: "TOGGLTRACK_TOKEN",
            },
            {
              name: "toggltrack_organization_id",
              label: "Organization ID",
              type: "text",
              required: false,
              help: "Default organization used by organization-scoped tools.",
              env: "TOGGLTRACK_ORGANIZATION_ID",
            },
            {
              name: "toggltrack_workspace_id",
              label: "Workspace ID",
              type: "text",
              required: false,
              help: "Default workspace used when a tool omits workspace_id.",
              env: "TOGGLTRACK_WORKSPACE_ID",
            },
          ]
        end

        # Prefer workspace probe (plan quota) over /me (30 req/hour user quota).
        def auth_status_cache_ttl = 600

        def fetch_auth_status
          load_credentials!
          organization_id = Emcp.sanitize_env_value(ENV["TOGGLTRACK_ORGANIZATION_ID"])
          workspace_id = Emcp.sanitize_env_value(ENV["TOGGLTRACK_WORKSPACE_ID"])

          if workspace_id.empty?
            probe_me(organization_id: organization_id, workspace_id: workspace_id)
          else
            probe_workspace(workspace_id, organization_id: organization_id)
          end
        rescue StandardError => e
          {
            authenticated: false,
            organization_id: Emcp.sanitize_env_value(ENV["TOGGLTRACK_ORGANIZATION_ID"]),
            workspace_id: Emcp.sanitize_env_value(ENV["TOGGLTRACK_WORKSPACE_ID"]),
            error: e.message,
          }
        end

        def apply_credentials(params)
          token = params["toggltrack_token"].to_s.strip
          organization_id = params["toggltrack_organization_id"].to_s.strip
          workspace_id = params["toggltrack_workspace_id"].to_s.strip
          apply_credentials_probe!(
            {
              "TOGGLTRACK_TOKEN" => token,
              "TOGGLTRACK_ORGANIZATION_ID" => organization_id,
              "TOGGLTRACK_WORKSPACE_ID" => workspace_id,
            },
            rejection_message: "Toggl Track API token was rejected",
          )
        ensure
          token = nil
        end

        def clear_credentials!
          persist_credentials!(
            "TOGGLTRACK_TOKEN" => nil,
            "TOGGLTRACK_ORGANIZATION_ID" => nil,
            "TOGGLTRACK_WORKSPACE_ID" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_account_tools
          define_project_tools
          define_tag_tools
          define_time_entry_tools
        end

        protected

        def credential_env_keys
          %w[
            TOGGLTRACK_TOKEN
            TOGGLTRACK_ORGANIZATION_ID
            TOGGLTRACK_WORKSPACE_ID
          ]
        end

        def replace_client!
          @client = Client.new
        end

        private

        def define_account_tools
          define_tool(
            name: "toggltrack_me",
            description: "Return the authenticated Toggl Track user profile.",
            properties: {
              with_related_data: boolean_prop("Include related projects, tags, workspaces, and time entries"),
            },
          ) do |with_related_data: false|
            api_get("/me", query: compact_hash(with_related_data: with_related_data || nil))
          end

          define_tool(
            name: "toggltrack_organizations",
            description: "List organizations for the authenticated user.",
          ) { api_get("/me/organizations") }

          define_tool(
            name: "toggltrack_organization",
            description: "Show one organization by ID.",
            properties: {
              organization_id: string_prop("Organization ID; defaults to TOGGLTRACK_ORGANIZATION_ID"),
            },
          ) do |organization_id: nil|
            api_get("/organizations/#{organization_id_value(organization_id)}")
          end

          define_tool(
            name: "toggltrack_workspaces",
            description: "List workspaces for the authenticated user.",
          ) { api_get("/me/workspaces") }

          define_tool(
            name: "toggltrack_workspace",
            description: "Show one workspace by ID.",
            properties: {
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
          ) do |workspace_id: nil|
            api_get("/workspaces/#{workspace_id_value(workspace_id)}")
          end
        end

        def define_project_tools
          define_tool(
            name: "toggltrack_projects",
            description: "List projects in a workspace.",
            properties: {
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
              active: string_prop("true, false, or both"),
              page: integer_prop("Page number"),
              per_page: integer_prop("Items per page, max 200"),
              name: string_prop("Project name filter"),
              search: string_prop("Search expression"),
            },
          ) do |workspace_id: nil, active: nil, page: nil, per_page: nil, name: nil, search: nil|
            api_get(
              "/workspaces/#{workspace_id_value(workspace_id)}/projects",
              query: compact_hash(
                active: active,
                page: page,
                per_page: per_page,
                name: name,
                search: search,
              ),
            )
          end

          define_tool(
            name: "toggltrack_project",
            description: "Get one workspace project.",
            properties: {
              project_id: string_prop("Project ID"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["project_id"],
          ) do |project_id:, workspace_id: nil|
            api_get("/workspaces/#{workspace_id_value(workspace_id)}/projects/#{path_id(project_id, "project_id")}")
          end

          define_tool(
            name: "toggltrack_project_create",
            description: "Create a workspace project from a raw JSON payload.",
            properties: {
              payload: object_prop("Project JSON body"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["payload"],
            write: true,
          ) do |payload:, workspace_id: nil|
            api_post(
              "/workspaces/#{workspace_id_value(workspace_id)}/projects",
              body: require_payload(payload),
            )
          end

          define_tool(
            name: "toggltrack_project_update",
            description: "Update a workspace project with a raw JSON payload.",
            properties: {
              project_id: string_prop("Project ID"),
              payload: object_prop("Project JSON body"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: %w[project_id payload],
            write: true,
          ) do |project_id:, payload:, workspace_id: nil|
            api_put(
              "/workspaces/#{workspace_id_value(workspace_id)}/projects/#{path_id(project_id, "project_id")}",
              body: require_payload(payload),
            )
          end

          define_tool(
            name: "toggltrack_project_delete",
            description: "Delete a workspace project.",
            properties: {
              project_id: string_prop("Project ID"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["project_id"],
            write: true,
          ) do |project_id:, workspace_id: nil|
            api_delete("/workspaces/#{workspace_id_value(workspace_id)}/projects/#{path_id(project_id, "project_id")}")
          end
        end

        def define_tag_tools
          define_tool(
            name: "toggltrack_tags",
            description: "List tags in a workspace.",
            properties: {
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
          ) do |workspace_id: nil|
            api_get("/workspaces/#{workspace_id_value(workspace_id)}/tags")
          end

          define_tool(
            name: "toggltrack_tag_create",
            description: "Create a workspace tag from a raw JSON payload.",
            properties: {
              payload: object_prop("Tag JSON body, usually {\"name\":\"...\"}"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["payload"],
            write: true,
          ) do |payload:, workspace_id: nil|
            api_post(
              "/workspaces/#{workspace_id_value(workspace_id)}/tags",
              body: require_payload(payload),
            )
          end

          define_tool(
            name: "toggltrack_tag_update",
            description: "Update a workspace tag with a raw JSON payload.",
            properties: {
              tag_id: string_prop("Tag ID"),
              payload: object_prop("Tag JSON body"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: %w[tag_id payload],
            write: true,
          ) do |tag_id:, payload:, workspace_id: nil|
            api_put(
              "/workspaces/#{workspace_id_value(workspace_id)}/tags/#{path_id(tag_id, "tag_id")}",
              body: require_payload(payload),
            )
          end

          define_tool(
            name: "toggltrack_tag_delete",
            description: "Delete a workspace tag.",
            properties: {
              tag_id: string_prop("Tag ID"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["tag_id"],
            write: true,
          ) do |tag_id:, workspace_id: nil|
            api_delete("/workspaces/#{workspace_id_value(workspace_id)}/tags/#{path_id(tag_id, "tag_id")}")
          end
        end

        def define_time_entry_tools
          define_tool(
            name: "toggltrack_time_entries",
            description: "List time entries for the authenticated user in a date window.",
            properties: {
              start_date: string_prop("RFC3339 start, for example 2026-07-01T00:00:00Z"),
              end_date: string_prop("RFC3339 end, for example 2026-07-26T23:59:59Z"),
              meta: boolean_prop("Include meta information when supported"),
              since: integer_prop("UNIX timestamp filter for changes since"),
            },
          ) do |start_date: nil, end_date: nil, meta: nil, since: nil|
            api_get(
              "/me/time_entries",
              query: compact_hash(
                start_date: start_date,
                end_date: end_date,
                meta: meta,
                since: since,
              ),
            )
          end

          define_tool(
            name: "toggltrack_time_entry_current",
            description: "Return the currently running time entry, if any.",
          ) { api_get("/me/time_entries/current") }

          define_tool(
            name: "toggltrack_time_entry",
            description: "Get one workspace time entry.",
            properties: {
              time_entry_id: string_prop("Time entry ID"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["time_entry_id"],
          ) do |time_entry_id:, workspace_id: nil|
            api_get(
              "/workspaces/#{workspace_id_value(workspace_id)}/time_entries/#{path_id(time_entry_id, "time_entry_id")}",
            )
          end

          define_tool(
            name: "toggltrack_time_entry_start",
            description: "Start a running time entry. Duration is forced to -1 unless already negative.",
            properties: {
              description: string_prop("Time entry description"),
              project_id: integer_prop("Optional project ID"),
              tags: array_prop("Optional tag names"),
              billable: boolean_prop("Billable flag"),
              start: string_prop("RFC3339 start timestamp; defaults to now in UTC"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
              payload: object_prop("Optional extra raw JSON fields merged into the request body"),
            },
            write: true,
          ) do |description: nil, project_id: nil, tags: nil, billable: nil, start: nil, workspace_id: nil, payload: {}|
            workspace = workspace_id_value(workspace_id).to_i
            body = stringify_keys(require_payload(payload)).merge(
              stringify_keys(
                compact_hash(
                  description: description,
                  project_id: project_id,
                  tags: tags,
                  billable: billable,
                  start: start || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
                  duration: -1,
                  workspace_id: workspace,
                  created_with: "emcp",
                  stop: nil,
                ),
              ),
            )
            body["duration"] = -1 unless body["duration"].to_i.negative?
            body["workspace_id"] = workspace
            body["created_with"] ||= "emcp"
            api_post("/workspaces/#{workspace}/time_entries", body: body)
          end

          define_tool(
            name: "toggltrack_time_entry_stop",
            description: "Stop a running workspace time entry.",
            properties: {
              time_entry_id: string_prop("Time entry ID"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["time_entry_id"],
            write: true,
          ) do |time_entry_id:, workspace_id: nil|
            workspace = workspace_id_value(workspace_id)
            api_patch(
              "/workspaces/#{workspace}/time_entries/#{path_id(time_entry_id, "time_entry_id")}/stop",
            )
          end

          define_tool(
            name: "toggltrack_time_entry_create",
            description: "Create a completed or custom time entry from a raw JSON payload.",
            properties: {
              payload: object_prop("Time entry JSON body"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["payload"],
            write: true,
          ) do |payload:, workspace_id: nil|
            workspace = workspace_id_value(workspace_id).to_i
            body = stringify_keys(require_payload(payload))
            body["workspace_id"] ||= workspace
            body["created_with"] ||= "emcp"
            api_post("/workspaces/#{body["workspace_id"]}/time_entries", body: body)
          end

          define_tool(
            name: "toggltrack_time_entry_update",
            description: "Update a workspace time entry with a raw JSON payload.",
            properties: {
              time_entry_id: string_prop("Time entry ID"),
              payload: object_prop("Time entry JSON body"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: %w[time_entry_id payload],
            write: true,
          ) do |time_entry_id:, payload:, workspace_id: nil|
            api_put(
              "/workspaces/#{workspace_id_value(workspace_id)}/time_entries/#{path_id(time_entry_id, "time_entry_id")}",
              body: require_payload(payload),
            )
          end

          define_tool(
            name: "toggltrack_time_entry_delete",
            description: "Delete a workspace time entry.",
            properties: {
              time_entry_id: string_prop("Time entry ID"),
              workspace_id: string_prop("Workspace ID; defaults to TOGGLTRACK_WORKSPACE_ID"),
            },
            required: ["time_entry_id"],
            write: true,
          ) do |time_entry_id:, workspace_id: nil|
            api_delete(
              "/workspaces/#{workspace_id_value(workspace_id)}/time_entries/#{path_id(time_entry_id, "time_entry_id")}",
            )
          end
        end

        def probe_workspace(workspace_id, organization_id:)
          result = @client.request(:get, "/workspaces/#{workspace_id}", raise_on_error: false)
          body = result[:body].is_a?(Hash) ? result[:body] : {}
          ok = result[:status].between?(200, 299)
          status = {
            authenticated: ok,
            probe: "workspace",
            workspace_id: workspace_id,
            organization_id: organization_id,
            workspace_name: body["name"],
          }
          unless ok
            detail = body.is_a?(Hash) ? (body["error"] || body["message"] || body) : body
            status[:error] = "Toggl Track API #{result[:status]}: #{detail}"
          end
          status
        end

        def probe_me(organization_id:, workspace_id:)
          result = @client.request(:get, "/me", raise_on_error: false)
          body = result[:body].is_a?(Hash) ? result[:body] : {}
          ok = result[:status].between?(200, 299)
          status = {
            authenticated: ok,
            probe: "me",
            email: body["email"],
            fullname: body["fullname"],
            default_workspace_id: body["default_workspace_id"],
            organization_id: organization_id,
            workspace_id: workspace_id,
          }
          unless ok
            detail = body.is_a?(Hash) ? (body["error"] || body["message"] || body) : body
            status[:error] = "Toggl Track API #{result[:status]}: #{detail}"
          end
          status
        end

        def organization_id_value(value = nil)
          id = value.to_s.strip
          id = ENV["TOGGLTRACK_ORGANIZATION_ID"].to_s.strip if id.empty?
          raise "organization_id is required" if id.empty?

          path_id(id, "organization_id")
        end

        def workspace_id_value(value = nil)
          id = value.to_s.strip
          id = ENV["TOGGLTRACK_WORKSPACE_ID"].to_s.strip if id.empty?
          raise "workspace_id is required" if id.empty?

          path_id(id, "workspace_id")
        end

        def path_id(value, label)
          id = value.to_s.strip
          raise "#{label} is required" if id.empty?
          raise "invalid #{label}" unless id.match?(/\A[0-9]+\z/)

          id
        end

        def require_payload(payload)
          raise "payload must be a JSON object" unless payload.is_a?(Hash)

          payload
        end

        def api_get(path, query: {})
          api_response { @client.get(path, query: query) }
        end

        def api_post(path, body:)
          api_response { @client.post(path, body: body) }
        end

        def api_put(path, body:)
          api_response { @client.put(path, body: body) }
        end

        def api_patch(path, body: nil)
          api_response { @client.patch(path, body: body) }
        end

        def api_delete(path)
          api_response { @client.delete(path) }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::TogglTrack::Server)
