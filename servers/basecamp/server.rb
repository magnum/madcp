# frozen_string_literal: true

require_relative "basecamp_client"

module Madcp
  module Servers
    module Basecamp
      class Server < ::McpServer
        server_id "basecamp"
        display_name "Basecamp"
        description "Projects, todos, cards, messages, chat, files, and schedules via the official Basecamp CLI."
        version "0.1.0"

        def self.default_service_token_refresh_in_minutes = 10_080 # weekly — CLI access tokens last ~2 weeks

        LIMIT_PROPERTIES = {
          limit: { type: "integer", description: "Maximum number of items" },
          fetch_all: { type: "boolean", description: "Fetch all pages instead of applying limit" },
        }.freeze
        after_initialize :ensure_runtime_client
        after_find :ensure_runtime_client

        def ensure_runtime_client
          return if defined?(@client) && @client
          replace_client! if respond_to?(:replace_client!, true)
        end

        def instructions
          "Use Basecamp tools to inspect and manage project data. " \
            "Call basecamp_skill before complex workflows. " \
            "Write tools are disabled unless allow_write_methods is enabled."
        end

        def auth_help_content
          {
            title: "Get Basecamp credentials",
            description: "Prefer importing the Basecamp CLI credentials file so MadCP can refresh tokens " \
                         "in the background. A pasted access token alone expires in ~2 weeks with no refresh.",
            steps: [
              "On a trusted computer: `BASECAMP_NO_KEYRING=1 basecamp auth login` " \
                "(forces a credentials.json even on macOS Keychain machines).",
              "Paste the contents of `~/.config/basecamp/credentials.json` into the credentials JSON field below " \
                "(or scp that file onto the server path shown in the help note).",
              "Set the numeric Account ID from https://3.basecamp.com/<account_id>/… " \
                "or `basecamp accounts list`.",
              "Optional fallback: paste only `basecamp auth token --quiet` (no auto-refresh).",
              "Save credentials — MadCP schedules a weekly CLI refresh when the credentials file is present.",
            ],
            commands: [
              { label: "Login (file-backed)", value: "BASECAMP_NO_KEYRING=1 basecamp auth login" },
              { label: "Show credentials file", value: "cat ~/.config/basecamp/credentials.json" },
              { label: "Copy access token only", value: "basecamp auth token --quiet" },
              { label: "Find the account ID", value: "basecamp accounts list" },
            ],
            note: "Server CLI home: #{cli_config_dir}. " \
                  "No Basecamp developer-portal renewal is required. Treat credentials.json as a secret.",
          }
        end

        def auth_fields
          [
            {
              name: "basecamp_account_id",
              label: "Basecamp account ID",
              type: "text",
              required: true,
              help: "Numeric ID from https://3.basecamp.com/<account_id>/… or `basecamp accounts list`.",
              env: "BASECAMP_ACCOUNT_ID",
            },
            {
              name: "basecamp_credentials_json",
              label: "CLI credentials.json (recommended)",
              type: "textarea",
              required: false,
              help: "Paste the full file from ~/.config/basecamp/credentials.json after " \
                    "BASECAMP_NO_KEYRING=1 basecamp auth login. Enables background refresh. " \
                    "Leave blank to keep the file already on the server.",
            },
            {
              name: "basecamp_token",
              label: "Basecamp access token (fallback)",
              type: "password",
              required: false,
              help: "Only if you are not importing credentials.json. Leave blank to keep a saved token.",
              env: "BASECAMP_TOKEN",
            },
          ]
        end

        def fetch_auth_status
          raw = @client.run(@client.auth_status, truncate: false)
          data = JSON.parse(raw)
          data = data["data"] || data
          authenticated = data["authenticated"] == true
          @client.run(@client.me, truncate: false) if authenticated
          {
            authenticated: authenticated,
            source: data["source"],
            account_id: ENV["BASECAMP_ACCOUNT_ID"],
            credentials_file: cli_credentials_present?,
          }
        rescue StandardError => e
          {
            authenticated: false,
            account_id: ENV["BASECAMP_ACCOUNT_ID"],
            credentials_file: cli_credentials_present?,
            error: e.message,
          }
        end

        def apply_credentials(params)
          load_credentials!
          account_id = Madcp.sanitize_env_value(params["basecamp_account_id"])
          token = Madcp.sanitize_env_value(params["basecamp_token"])
          credentials_json = params["basecamp_credentials_json"].to_s.strip

          old_token = ENV["BASECAMP_TOKEN"]
          old_account = ENV["BASECAMP_ACCOUNT_ID"]
          old_credentials = File.file?(cli_credentials_path) ? File.read(cli_credentials_path) : nil

          write_cli_credentials_json!(credentials_json) if credentials_json.present?

          updates = {}
          updates["BASECAMP_ACCOUNT_ID"] = account_id if account_id.present?
          updates["BASECAMP_TOKEN"] = token if token.present?

          effective_account = updates["BASECAMP_ACCOUNT_ID"].presence ||
            Madcp.sanitize_env_value(ENV["BASECAMP_ACCOUNT_ID"])
          effective_token = updates["BASECAMP_TOKEN"].presence ||
            Madcp.sanitize_env_value(ENV["BASECAMP_TOKEN"])

          raise "Basecamp account ID is required" if effective_account.empty?
          unless cli_credentials_present? || effective_token.present?
            raise "Import credentials.json (recommended) or paste a Basecamp access token"
          end

          write_cli_config!(account_id: effective_account)
          persist_payload = { "BASECAMP_ACCOUNT_ID" => effective_account }
          if cli_credentials_present? && token.blank?
            # Prefer CLI file refresh; do not pin a pasted/stale access token in ENV.
            persist_payload["BASECAMP_TOKEN"] = nil
          elsif effective_token.present?
            persist_payload["BASECAMP_TOKEN"] = effective_token
          end
          persist_credentials!(persist_payload)

          replace_client!
          status = auth_status(force: true)
          if status[:authenticated]
            sync_access_token_from_cli! if cli_credentials_present?
            schedule_service_token_refresh_job!
            return true
          end

          restore_cli_credentials!(old_credentials)
          persist_credentials!(
            "BASECAMP_TOKEN" => old_token,
            "BASECAMP_ACCOUNT_ID" => old_account,
          )
          replace_client!
          detail = status[:error].presence || "authenticated=false"
          raise "Basecamp token rejected or account ID is invalid (#{detail}). " \
                "Prefer importing credentials.json from `BASECAMP_NO_KEYRING=1 basecamp auth login`, " \
                "or paste a fresh access token. Account ID is the number in https://3.basecamp.com/<id>/…"
        ensure
          token = nil
          credentials_json = nil
        end

        def clear_credentials!
          FileUtils.rm_f(cli_credentials_path)
          persist_credentials!("BASECAMP_TOKEN" => nil, "BASECAMP_ACCOUNT_ID" => nil)
          replace_client!
          @client.run(@client.auth_logout, truncate: false)
        rescue CliError
          nil
        end

        # Uses the Basecamp CLI’s own OAuth refresh against credentials.json, then syncs the access token.
        def refresh_service_token!
          return false unless cli_credentials_present?

          load_credentials!
          replace_client!
          @client.run(@client.me, truncate: false)
          sync_access_token_from_cli!
          true
        rescue StandardError => e
          Rails.logger.warn("[basecamp] service token refresh failed: #{e.message}")
          false
        end

        def configure_tools
          define_skill
          define_project_tools
          define_todo_tools
          define_collaboration_tools
          define_cross_project_tools
        end

        def replace_client!
          @client = Client.new(env: cli_process_env)
        end

        def cli_home
          path = File.join(data_dir, "home")
          FileUtils.mkdir_p(File.join(path, ".config", "basecamp"), mode: 0o700)
          path
        end

        def cli_config_dir
          File.join(cli_home, ".config", "basecamp")
        end

        def cli_credentials_path
          File.join(cli_config_dir, "credentials.json")
        end

        def cli_credentials_present?
          File.file?(cli_credentials_path) && File.size(cli_credentials_path).positive?
        end

        protected

        def credential_env_keys = %w[BASECAMP_TOKEN BASECAMP_ACCOUNT_ID]

        private

        def cli_process_env
          env = {
            "BASECAMP_NO_KEYRING" => "1",
            "HOME" => cli_home,
            "XDG_CONFIG_HOME" => File.join(cli_home, ".config"),
            "BASECAMP_ACCOUNT_ID" => Madcp.sanitize_env_value(ENV["BASECAMP_ACCOUNT_ID"]),
          }

          if cli_credentials_present?
            # Let the CLI read/refresh credentials.json — do not pin a stale access token.
            env["BASECAMP_TOKEN"] = nil
          else
            token = Madcp.sanitize_env_value(ENV["BASECAMP_TOKEN"])
            env["BASECAMP_TOKEN"] = token if token.present?
          end

          env
        end

        def write_cli_credentials_json!(raw)
          data = JSON.parse(raw)
          raise "credentials.json must be a JSON object" unless data.is_a?(Hash)

          FileUtils.mkdir_p(cli_config_dir, mode: 0o700)
          File.write(cli_credentials_path, JSON.pretty_generate(data), perm: 0o600)
        rescue JSON::ParserError => e
          raise "Invalid credentials.json: #{e.message}"
        end

        def write_cli_config!(account_id:)
          path = File.join(cli_config_dir, "config.json")
          current = File.file?(path) ? JSON.parse(File.read(path)) : {}
          current = {} unless current.is_a?(Hash)
          current["account_id"] = account_id.to_s
          FileUtils.mkdir_p(cli_config_dir, mode: 0o700)
          File.write(path, JSON.pretty_generate(current), perm: 0o600)
        rescue JSON::ParserError
          File.write(path, JSON.pretty_generate({ "account_id" => account_id.to_s }), perm: 0o600)
        end

        def restore_cli_credentials!(old_credentials)
          if old_credentials.nil?
            FileUtils.rm_f(cli_credentials_path)
          else
            File.write(cli_credentials_path, old_credentials, perm: 0o600)
          end
        end

        def sync_access_token_from_cli!
          raw = @client.run(@client.auth_token, truncate: false).to_s.strip
          token = Madcp.sanitize_env_value(raw)
          return if token.empty?

          persist_credentials!("BASECAMP_TOKEN" => token)
        ensure
          token = nil
        end

        def define_skill
          path = File.join(__dir__, "skills", "basecamp", "SKILL.md")
          define_resource(
            uri: "basecamp://skill",
            name: "basecamp_skill",
            description: "Official Basecamp CLI agent skill.",
            mime_type: "text/markdown",
          ) { File.read(path) }
          define_tool(
            name: "basecamp_skill",
            description: "Return the official Basecamp CLI workflows, URL rules, and command reference.",
          ) { text_response(File.read(path)) }
        end

        def run(*parts, **options)
          cli_response(@client, @client.command(*parts, **options))
        end

        def project_prop = string_prop("Project ID or name")

        def define_project_tools
          define_tool(name: "basecamp_auth_status", description: "Show Basecamp CLI authentication status.") do
            cli_response(@client, @client.auth_status)
          end

          define_tool(
            name: "basecamp_auth_token",
            description: "Print the Basecamp access token. Sensitive; use only when explicitly needed.",
          ) { cli_response(@client, @client.auth_token) }

          define_tool(name: "basecamp_config_show", description: "Show Basecamp CLI configuration.") do
            cli_response(@client, @client.config_show)
          end

          define_tool(
            name: "basecamp_projects",
            description: "List Basecamp projects.",
            properties: LIMIT_PROPERTIES,
          ) { |limit: nil, fetch_all: false| run("projects", "list", limit: limit, fetch_all: fetch_all) }

          define_tool(
            name: "basecamp_project_show",
            description: "Show one Basecamp project.",
            properties: { id: string_prop("Project ID") },
            required: ["id"],
          ) { |id:| run("projects", "show", id) }

          define_tool(
            name: "basecamp_people",
            description: "List people, optionally scoped to a project.",
            properties: { project: project_prop, **LIMIT_PROPERTIES },
          ) do |project: nil, limit: nil, fetch_all: false|
            run("people", "list", limit: limit, fetch_all: fetch_all, options: { "--project" => project })
          end

          define_tool(name: "basecamp_me", description: "Show the current Basecamp user.") { cli_response(@client, @client.me) }

          define_tool(
            name: "basecamp_search",
            description: "Search Basecamp.",
            properties: {
              query: string_prop("Search query"),
              limit: integer_prop("Maximum number of results"),
              sort: string_prop("Sort mode"),
            },
            required: ["query"],
          ) { |query:, limit: nil, sort: nil| run("search", query, limit: limit, options: { "--sort" => sort }) }

          define_tool(
            name: "basecamp_url_parse",
            description: "Parse a Basecamp URL into its resource identifiers.",
            properties: { url: string_prop("Basecamp URL") },
            required: ["url"],
          ) { |url:| run("url", "parse", url) }
        end

        def define_todo_tools
          define_tool(
            name: "basecamp_todolists",
            description: "List todo lists in a project.",
            properties: { project: project_prop, **LIMIT_PROPERTIES },
            required: ["project"],
          ) { |project:, limit: nil, fetch_all: false| run("todolists", "list", project: project, limit: limit, fetch_all: fetch_all) }

          define_tool(
            name: "basecamp_todos",
            description: "List todos in a project.",
            properties: {
              project: project_prop,
              list: string_prop("Todo list ID or name"),
              assignee: string_prop("Assignee ID or name"),
              status: string_prop("Todo status"),
              overdue: boolean_prop("Only overdue todos"),
              **LIMIT_PROPERTIES,
            },
            required: ["project"],
          ) do |project:, list: nil, assignee: nil, status: nil, overdue: false, limit: nil, fetch_all: false|
            run(
              "todos", "list",
              project: project,
              limit: limit,
              fetch_all: fetch_all,
              options: { "--list" => list, "--assignee" => assignee, "--status" => status },
              flags: { "--overdue" => overdue },
            )
          end

          define_tool(
            name: "basecamp_todo_show",
            description: "Show one todo.",
            properties: { id: string_prop("Todo ID"), project: project_prop },
            required: ["id"],
          ) { |id:, project: nil| run("todos", "show", id, project: project) }

          define_tool(
            name: "basecamp_todolist_create",
            description: "Create a todo list.",
            properties: {
              name: string_prop("List name"),
              project: project_prop,
              description: string_prop("List description"),
            },
            required: %w[name project],
            write: true,
          ) { |name:, project:, description: nil| run("todolists", "create", name, project: project, options: { "--description" => description }) }

          define_tool(
            name: "basecamp_todo_create",
            description: "Create a todo.",
            properties: {
              content: string_prop("Todo title"),
              project: project_prop,
              list: string_prop("Todo list ID or name"),
              assignee: string_prop("Assignee ID or name"),
              due: string_prop("Due date YYYY-MM-DD"),
              description: string_prop("Todo description"),
            },
            required: %w[content project],
            write: true,
          ) do |content:, project:, list: nil, assignee: nil, due: nil, description: nil|
            run(
              "todos", "create", content,
              project: project,
              options: {
                "--list" => list, "--assignee" => assignee,
                "--due" => due, "--description" => description,
              },
            )
          end

          define_tool(
            name: "basecamp_todo_update",
            description: "Update a todo's title, description, dates, or assignee.",
            properties: {
              id: string_prop("Todo ID"),
              project: project_prop,
              title: string_prop("New title"),
              description: string_prop("New description"),
              due: string_prop("New due date"),
              starts_on: string_prop("New start date"),
              assignee: string_prop("New assignee"),
              notify: boolean_prop("Notify subscribers"),
              no_description: boolean_prop("Clear description"),
              no_due: boolean_prop("Clear due date"),
              no_starts_on: boolean_prop("Clear start date"),
            },
            required: ["id"],
            write: true,
          ) do |id:, project: nil, title: nil, description: nil, due: nil, starts_on: nil,
                   assignee: nil, notify: false, no_description: false, no_due: false,
                   no_starts_on: false|
            run(
              "todos", "update", id,
              project: project,
              options: {
                "--title" => title,
                "--description" => no_description ? nil : description,
                "--due" => no_due ? nil : due,
                "--starts-on" => no_starts_on ? nil : starts_on,
                "--assignee" => assignee,
              },
              flags: {
                "--notify" => notify, "--no-description" => no_description,
                "--no-due" => no_due, "--no-starts-on" => no_starts_on,
              },
            )
          end

          define_tool(
            name: "basecamp_todo_complete",
            description: "Complete one or more todos.",
            properties: { ids: array_prop("Todo IDs") },
            required: ["ids"],
            write: true,
          ) { |ids:| run("todos", "complete", *ids) }

          define_tool(
            name: "basecamp_todo_reopen",
            description: "Reopen a completed todo.",
            properties: { id: string_prop("Todo ID") },
            required: ["id"],
            write: true,
          ) { |id:| run("todos", "uncomplete", id) }

          define_tool(
            name: "basecamp_assign",
            description: "Assign todos, cards, or card steps to a person.",
            properties: {
              ids: array_prop("Todo, card, or step IDs"),
              to: string_prop("Assignee: me, name, or person ID"),
              project: project_prop,
              kind: string_prop("todo, card, or step"),
            },
            required: %w[ids to project],
            write: true,
          ) do |ids:, to:, project:, kind: nil|
            unless kind.nil? || %w[todo card step].include?(kind)
              next text_response("ERROR: kind must be todo, card, or step")
            end

            flags = {
              "--card" => kind == "card",
              "--step" => kind == "step",
            }
            run("assign", *ids, project: project, options: { "--to" => to }, flags: flags)
          end
        end

        def define_collaboration_tools
          define_tool(
            name: "basecamp_cards",
            description: "List card-table cards.",
            properties: {
              project: project_prop,
              card_table: string_prop("Card table ID"),
              column: string_prop("Column ID or name"),
              **LIMIT_PROPERTIES,
            },
            required: ["project"],
          ) do |project:, card_table: nil, column: nil, limit: nil, fetch_all: false|
            run("cards", "list", project: project, limit: limit, fetch_all: fetch_all,
                                 options: { "--card-table" => card_table, "--column" => column })
          end

          define_tool(
            name: "basecamp_card_show",
            description: "Show one card.",
            properties: { id: string_prop("Card ID"), project: project_prop },
            required: %w[id project],
          ) { |id:, project:| run("cards", "show", id, project: project) }

          define_tool(
            name: "basecamp_card_create",
            description: "Create a card.",
            properties: {
              title: string_prop("Card title"), content: string_prop("Card content"),
              project: project_prop, column: string_prop("Column ID or name"),
            },
            required: %w[title project],
            write: true,
          ) do |title:, project:, content: nil, column: nil|
            parts = ["cards", "create", title]
            parts << content if content
            run(*parts, project: project, options: { "--column" => column })
          end

          define_tool(
            name: "basecamp_card_move",
            description: "Move a card to another column.",
            properties: {
              id: string_prop("Card ID"), to: string_prop("Destination column"),
              project: project_prop, position: integer_prop("Position"),
              card_table: string_prop("Card table ID"), on_hold: boolean_prop("Put card on hold"),
            },
            required: %w[id to project],
            write: true,
          ) do |id:, to:, project:, position: nil, card_table: nil, on_hold: false|
            run("cards", "move", id, project: project,
                                     options: { "--to" => to, "--position" => position, "--card-table" => card_table },
                                     flags: { "--on-hold" => on_hold })
          end

          define_tool(
            name: "basecamp_columns",
            description: "List card-table columns.",
            properties: { project: project_prop, card_table: string_prop("Card table ID") },
            required: ["project"],
          ) { |project:, card_table: nil| run("cards", "columns", project: project, options: { "--card-table" => card_table }) }

          define_message_tools
          define_chat_tools
        end

        def define_message_tools
          define_tool(
            name: "basecamp_messages",
            description: "List message-board messages.",
            properties: { project: project_prop, **LIMIT_PROPERTIES },
            required: ["project"],
          ) { |project:, limit: nil, fetch_all: false| run("messages", "list", project: project, limit: limit, fetch_all: fetch_all) }

          define_tool(
            name: "basecamp_message_show",
            description: "Show one message.",
            properties: { id: string_prop("Message ID"), project: project_prop },
            required: ["id"],
          ) { |id:, project: nil| run("messages", "show", id, project: project) }

          define_tool(
            name: "basecamp_message_create",
            description: "Create a message-board message.",
            properties: {
              title: string_prop("Message title"), body: string_prop("Message body"),
              project: project_prop, no_subscribe: boolean_prop("Do not subscribe"),
            },
            required: %w[title body project],
            write: true,
          ) do |title:, body:, project:, no_subscribe: false|
            run("messages", "create", title, body, project: project, flags: { "--no-subscribe" => no_subscribe })
          end

          define_tool(
            name: "basecamp_comments",
            description: "List comments on a recording.",
            properties: { recording_id: string_prop("Recording ID"), project: project_prop, **LIMIT_PROPERTIES },
            required: %w[recording_id project],
          ) do |recording_id:, project:, limit: nil, fetch_all: false|
            run("comments", "list", recording_id, project: project, limit: limit, fetch_all: fetch_all)
          end

          define_tool(
            name: "basecamp_comment_create",
            description: "Add a comment to a recording.",
            properties: {
              recording_id: string_prop("Recording ID"), content: string_prop("Comment body"),
              project: project_prop,
            },
            required: %w[recording_id content project],
            write: true,
          ) { |recording_id:, content:, project:| run("comments", "create", recording_id, content, project: project) }
        end

        def define_chat_tools
          define_tool(
            name: "basecamp_chat_messages",
            description: "List Campfire chat messages.",
            properties: { project: project_prop, **LIMIT_PROPERTIES },
            required: ["project"],
          ) { |project:, limit: nil, fetch_all: false| run("chat", "messages", project: project, limit: limit, fetch_all: fetch_all) }

          define_tool(
            name: "basecamp_chat_post",
            description: "Post a Campfire chat message.",
            properties: { content: string_prop("Message body"), project: project_prop },
            required: %w[content project],
            write: true,
          ) { |content:, project:| run("chat", "post", content, project: project) }
        end

        def define_cross_project_tools
          define_tool(
            name: "basecamp_files",
            description: "List files in a project.",
            properties: {
              project: project_prop, vault: string_prop("Vault ID"), **LIMIT_PROPERTIES,
            },
            required: ["project"],
          ) do |project:, vault: nil, limit: nil, fetch_all: false|
            run("files", "list", project: project, limit: limit, fetch_all: fetch_all, options: { "--vault" => vault })
          end

          define_tool(
            name: "basecamp_schedule",
            description: "List schedule entries.",
            properties: { project: project_prop, **LIMIT_PROPERTIES },
            required: ["project"],
          ) { |project:, limit: nil, fetch_all: false| run("schedule", "entries", project: project, limit: limit, fetch_all: fetch_all) }

          define_tool(name: "basecamp_assignments", description: "List assignments.", properties: {
            scope: string_prop("Optional due scope"),
          }) { |scope: nil| scope ? run("assignments", "due", scope) : run("assignments") }

          define_tool(
            name: "basecamp_notifications",
            description: "List notifications.",
            properties: { page: integer_prop("Page number") },
          ) { |page: nil| run("notifications", options: { "--page" => page }) }

          define_tool(
            name: "basecamp_timeline",
            description: "Show activity timeline.",
            properties: { project: project_prop, **LIMIT_PROPERTIES },
          ) { |project: nil, limit: nil, fetch_all: false| run("timeline", project: project, limit: limit, fetch_all: fetch_all) }

          define_tool(
            name: "basecamp_recordings",
            description: "List recordings by type.",
            properties: {
              type: string_prop("Recording type"), project: project_prop,
              status: string_prop("Recording status"), **LIMIT_PROPERTIES,
            },
            required: ["type"],
          ) do |type:, project: nil, status: nil, limit: nil, fetch_all: false|
            run("recordings", type, project: project, limit: limit, fetch_all: fetch_all, options: { "--status" => status })
          end

          define_tool(name: "basecamp_doctor", description: "Run Basecamp CLI diagnostics.") do
            cli_response(@client, @client.doctor)
          end
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::Basecamp::Server)
