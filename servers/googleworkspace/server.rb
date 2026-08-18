# frozen_string_literal: true

require "fileutils"
require_relative "googleworkspace_client"

module Madcp
  module Servers
    module GoogleWorkspace
      class Server < ::McpServer
        server_id "googleworkspace"
        display_name "Google Workspace"
        description "Google Docs, Sheets, Drive, and every Workspace API exposed dynamically by the gws CLI."
        version "0.1.0"

        SAFE_READ_METHODS = %w[get list search lookup query export download batchGet].freeze
        DEFAULT_COMMENT_FIELDS =
          "id,content,htmlContent,author,createdTime,modifiedTime,resolved,deleted,anchor," \
          "quotedFileContent,replies(id,content,htmlContent,author,createdTime,modifiedTime,action)"
        DEFAULT_REPLY_FIELDS =
          "id,content,htmlContent,author,createdTime,modifiedTime,action"
        after_initialize :ensure_runtime_client
        after_find :ensure_runtime_client

        def ensure_runtime_client
          return if defined?(@client) && @client
          replace_client! if respond_to?(:replace_client!, true)
        end

        def instructions
          "Use typed Google Docs and Sheets tools for common document editing. " \
            "googleworkspace_doc_batch_update always applies direct edits " \
            "(Docs API has no suggestion/review mode). " \
            "For review feedback without rewriting the doc, use googleworkspace_drive_comment_create " \
            "(optional anchor_line / quoted_text). Workspace editor UIs treat API-defined anchors " \
            "as unanchored, but comments still appear under All Comments; reply/resolve via " \
            "googleworkspace_drive_comment_reply. " \
            "Drive file tools enable shared-drive access by default via supportsAllDrives. " \
            "Use googleworkspace_discover and googleworkspace_schema to inspect any other Workspace API. " \
            "The unrestricted generic API tool is write-gated."
        end

        def auth_help_content
          {
            title: "Prepare Google Workspace credentials",
            description: "Run these commands on a trusted computer where gws can open a browser. " \
                         "Then paste the complete exported JSON into the credentials field below.",
            steps: [
              "Set up or select the Google Cloud project and enable the Workspace APIs.",
              "Sign in with the Google account MadCP should use.",
              "Verify the active credential source and the project associated with the OAuth client.",
              "Export unmasked credentials containing the refresh token.",
              "Set GOOGLE_WORKSPACE_PROJECT_ID in MadCP to make quota and billing attribution explicit.",
            ],
            commands: [
              { label: "Set up the Google Cloud project", value: "gws auth setup" },
              { label: "Authorize your Google account", value: "gws auth login" },
              { label: "Inspect active authentication", value: "gws auth status" },
              {
                label: "Read the project ID from the default OAuth client",
                value: "jq -r '.installed.project_id // .web.project_id // .project_id' ~/.config/gws/client_secret.json",
              },
              { label: "Export credentials for MadCP", value: "gws auth export --unmasked" },
            ],
            note: "Paste only the JSON object from gws auth export --unmasked, not the " \
                  "Using keyring backend line. Leave the short-lived access token field empty: " \
                  "GOOGLE_WORKSPACE_CLI_TOKEN overrides the refresh-token file and expires quickly. " \
                  "The exported authorized_user JSON may not contain the project ID — set " \
                  "GOOGLE_WORKSPACE_PROJECT_ID explicitly. Paste credentials only over HTTPS.",
          }
        end

        def auth_fields
          [
            {
              name: "googleworkspace_credentials_json",
              label: "Exported gws credentials JSON",
              type: "textarea",
              required: false,
              help: "Preferred: gws auth export --unmasked (includes refresh_token).",
              value: -> { File.file?(credentials_path) ? File.read(credentials_path) : "" },
            },
            {
              name: "googleworkspace_project_id",
              label: "Google Cloud project ID",
              type: "text",
              required: false,
              help: "Recommended: explicitly sets the project used for quota, billing, and gws helpers.",
              env: "GOOGLE_WORKSPACE_PROJECT_ID",
            },
            {
              name: "googleworkspace_token",
              label: "Short-lived access token (discouraged)",
              type: "password",
              required: false,
              help: "Avoid in Docker. Overrides the credentials file and expires in ~1 hour.",
              env: "GOOGLE_WORKSPACE_CLI_TOKEN",
            },
          ]
        end

        def fetch_auth_status
          raw = @client.auth_status
          parsed = parse_gws_json(raw)
          data = parsed["data"] || parsed
          credentials = credentials_file_status
          authenticated = google_authenticated?(data, credentials)
          {
            authenticated: authenticated,
            auth_method: data["auth_method"],
            credential_source: data["credential_source"],
            token_valid: data["token_valid"],
            token_error: data["token_error"] || data["error_description"] || data["error"],
            plain_credentials_exists: data["plain_credentials_exists"],
            encrypted_credentials_exists: data["encrypted_credentials_exists"],
            credentials_type: credentials[:type],
            credentials_file_valid: credentials[:valid],
            credentials_file_error: credentials[:error],
            project_id: ENV["GOOGLE_WORKSPACE_PROJECT_ID"] || data["project_id"],
            credentials_file: ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"],
            gws_status: data,
          }
        rescue StandardError => e
          {
            authenticated: false,
            project_id: ENV["GOOGLE_WORKSPACE_PROJECT_ID"],
            credentials_file: ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"],
            error: e.message,
          }
        end

        def apply_credentials(params)
          old_env = credential_env_keys.to_h { |key| [key, ENV[key]] }
          old_credentials = File.binread(credentials_path) if File.file?(credentials_path)
          token = params["googleworkspace_token"].to_s.strip
          credentials_json = params["googleworkspace_credentials_json"].to_s.strip
          project_id = params["googleworkspace_project_id"].to_s.strip

          updates = {
            "GOOGLE_WORKSPACE_PROJECT_ID" => project_id,
            "GOOGLE_WORKSPACE_CLI_TOKEN" => token,
          }
          if !credentials_json.empty?
            begin
              parsed = JSON.parse(credentials_json)
            rescue JSON::ParserError => e
              raise "Invalid Google Workspace credentials JSON: #{e.message}"
            end
            raise "Google Workspace credentials must be a JSON object" unless parsed.is_a?(Hash)
            validate_credentials_json!(parsed)

            FileUtils.mkdir_p(File.dirname(credentials_path))
            File.write(credentials_path, JSON.pretty_generate(parsed) + "\n", perm: 0o600)
            sync_gws_plain_credentials!(parsed)
            updates["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"] = credentials_path
            # Refresh-token file must win: a stale CLI_TOKEN shadows it and breaks all API calls.
            updates["GOOGLE_WORKSPACE_CLI_TOKEN"] = nil
          else
            File.delete(credentials_path) if File.file?(credentials_path)
            plain = File.join(gws_config_dir, "credentials.json")
            File.delete(plain) if File.file?(plain)
            updates["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"] = nil
          end
          persist_credentials!(updates)
          @client = Client.new
          status = auth_status(force: true)
          unless status[:authenticated]
            raise authentication_failure_message(status)
          end

          true
        rescue StandardError => e
          if old_credentials
            File.binwrite(credentials_path, old_credentials)
            File.chmod(0o600, credentials_path)
          else
            File.delete(credentials_path) if File.file?(credentials_path)
          end
          persist_credentials!(old_env)
          @client = Client.new
          raise e.message
        ensure
          token = nil
          credentials_json = nil
        end

        def clear_credentials!
          File.delete(credentials_path) if File.file?(credentials_path)
          plain = File.join(gws_config_dir, "credentials.json")
          File.delete(plain) if File.file?(plain)
          persist_credentials!(
            "GOOGLE_WORKSPACE_CLI_TOKEN" => nil,
            "GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE" => nil,
            "GOOGLE_WORKSPACE_PROJECT_ID" => nil,
          )
          @client = Client.new
        end

        def configure_tools
          define_discovery_tools
          define_drive_tools
          define_docs_tools
          define_sheets_tools
          define_generic_api_tools
        end

        def replace_client!
          @client = Client.new
        end

        protected

        def credential_env_keys
          %w[
            GOOGLE_WORKSPACE_CLI_TOKEN
            GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE
            GOOGLE_WORKSPACE_PROJECT_ID
          ]
        end

        private

        def credentials_path
          File.join(data_dir, "credentials.json")
        end

        def gws_config_dir
          ENV.fetch("GOOGLE_WORKSPACE_CLI_CONFIG_DIR") do
            File.join(Dir.home, ".config", "gws")
          end
        end

        def sync_gws_plain_credentials!(credentials)
          FileUtils.mkdir_p(gws_config_dir)
          target = File.join(gws_config_dir, "credentials.json")
          File.write(target, JSON.pretty_generate(credentials) + "\n", perm: 0o600)
        end

        def google_authenticated?(data, credentials)
          source = data["credential_source"].to_s
          # gws may report token_valid for a cached/file token while an expired
          # GOOGLE_WORKSPACE_CLI_TOKEN still wins at request time.
          return false if source == "token_env_var" && durable_credentials_file?

          return true if data["authenticated"] == true
          return true if data["token_valid"] == true && source != "token_env_var"
          return true if %w[authenticated success ok].include?(data["status"].to_s.downcase)
          return false if data["token_valid"] == false

          if credentials[:valid]
            return true if credentials[:type] == "service_account"
            if credentials[:type] == "authorized_user"
              return true if data["plain_credentials_exists"] == true
              return true if data["encrypted_credentials_exists"] == true
              return true if data["auth_method"].to_s == "oauth2"
              return true if File.file?(ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"].to_s)
            end
          end

          false
        end

        def durable_credentials_file?
          path = ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"].to_s
          return false if path.empty? || !File.file?(path)

          credentials_file_status[:valid] == true
        end

        def prefer_credentials_file_over_token!
          return unless durable_credentials_file?
          return if ENV["GOOGLE_WORKSPACE_CLI_TOKEN"].to_s.empty?

          persist_credentials!("GOOGLE_WORKSPACE_CLI_TOKEN" => nil)
        end

        def authentication_failure_message(status)
          details = []
          details << status[:token_error] if status[:token_error]
          details << status[:credentials_file_error] if status[:credentials_file_error]
          details << status[:error] if status[:error]

          if status[:credential_source].to_s == "token_env_var"
            details << "GOOGLE_WORKSPACE_CLI_TOKEN is set and overrides the refresh-token credentials file; clear it"
          end
          if status[:credentials_file].to_s.empty?
            details << "no credentials file was stored"
          elsif status[:credentials_file_valid] == false
            details << "stored credentials file is invalid"
          elsif status[:plain_credentials_exists] == false && status[:encrypted_credentials_exists] == false
            details << "gws did not see the credentials file at #{status[:credentials_file]}"
          elsif status[:token_valid] == false
            details << "gws rejected the refresh token"
          elsif status[:token_valid].nil?
            details << "gws could not validate the refresh token (often outbound HTTPS from the container, or a revoked/masked token)"
          end

          message = "Google Workspace CLI is not authenticated"
          message += ": #{details.join("; ")}" unless details.empty?
          if status[:gws_status]
            message += " | gws auth status: #{JSON.generate(status[:gws_status])}"
          end
          message
        end

        def validate_credentials_json!(credentials)
          type = credentials["type"].to_s
          required = case type
                     when "authorized_user"
                       %w[client_id client_secret refresh_token]
                     when "service_account"
                       %w[client_email private_key]
                     else
                       raise "Unsupported Google credential type '#{type}'. " \
                             "Use gws auth export --unmasked or a service-account JSON file."
                     end
          missing = required.select { |key| credentials[key].to_s.empty? }
          return if missing.empty?

          raise "Google #{type} credentials are missing: #{missing.join(", ")}"
        end

        def credentials_file_status
          path = ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"].to_s
          return { valid: false, type: nil } if path.empty? || !File.file?(path)

          credentials = JSON.parse(File.read(path))
          validate_credentials_json!(credentials)
          { valid: true, type: credentials["type"] }
        rescue StandardError => e
          { valid: false, type: credentials&.dig("type"), error: e.message }
        end

        def parse_gws_json(raw)
          json_start = raw.to_s.index("{")
          raise "gws returned no JSON authentication status" unless json_start

          JSON.parse(raw[json_start..])
        end

        def define_discovery_tools
          define_tool(
            name: "googleworkspace_discover",
            description: "Browse gws services, resources, methods, and flags using CLI help.",
            properties: {
              path: array_prop("Optional path such as [\"sheets\", \"spreadsheets\", \"values\"]"),
            },
          ) { |path: []| gws_call { @client.help(path) } }

          define_tool(
            name: "googleworkspace_schema",
            description: "Return the dynamic Google Discovery schema for an API method.",
            properties: {
              method_path: string_prop("Dotted path, for example sheets.spreadsheets.values.get"),
            },
            required: ["method_path"],
          ) { |method_path:| gws_call { @client.schema(method_path) } }

          define_tool(
            name: "googleworkspace_auth_status",
            description: "Show gws authentication and credential status.",
          ) { gws_call { @client.auth_status } }
        end

        def define_drive_tools
          define_tool(
            name: "googleworkspace_drive_files",
            description: "List or search Google Drive files, including shared drives.",
            properties: {
              query: string_prop("Drive q expression"),
              page_size: integer_prop("Maximum files"),
              page_token: string_prop("Pagination token"),
              order_by: string_prop("Drive orderBy expression"),
              fields: string_prop("Response field mask"),
              corpora: string_prop("user, domain, drive, or allDrives; defaults to allDrives"),
              drive_id: string_prop("Shared drive ID when corpora is drive"),
            },
          ) do |query: nil, page_size: 50, page_token: nil, order_by: nil, fields: nil, corpora: nil, drive_id: nil|
            params = compact_hash(
              q: query,
              pageSize: page_size,
              pageToken: page_token,
              orderBy: order_by,
              fields: fields,
              corpora: corpora,
              driveId: drive_id,
            )
            gws_api("drive", ["files"], "list", params: params)
          end

          define_tool(
            name: "googleworkspace_drive_file",
            description: "Get Google Drive file metadata, including files on shared drives.",
            properties: {
              file_id: string_prop("Drive file ID"),
              fields: string_prop("Response field mask"),
            },
            required: ["file_id"],
          ) do |file_id:, fields: nil|
            gws_api("drive", ["files"], "get", params: compact_hash(fileId: file_id, fields: fields))
          end

          define_tool(
            name: "googleworkspace_drive_comments_list",
            description: "List Drive comments on a file (Google Docs, Sheets, etc.). " \
                         "Requires a fields mask; MadCP supplies a useful default.",
            properties: {
              file_id: string_prop("Drive file ID (same as Docs document ID for Google Docs)"),
              include_deleted: boolean_prop("Include deleted comments"),
              page_size: integer_prop("Maximum comments per page (max 100)"),
              page_token: string_prop("Pagination token"),
              start_modified_time: string_prop("RFC 3339 lower bound for modifiedTime"),
              fields: string_prop("Response field mask (required by Drive; MadCP default if omitted)"),
            },
            required: ["file_id"],
          ) do |file_id:, include_deleted: nil, page_size: nil, page_token: nil, start_modified_time: nil, fields: nil|
            gws_api(
              "drive",
              ["comments"],
              "list",
              params: compact_hash(
                fileId: file_id,
                includeDeleted: include_deleted,
                pageSize: page_size,
                pageToken: page_token,
                startModifiedTime: start_modified_time,
                fields: drive_comment_fields(fields),
              ),
            )
          end

          define_tool(
            name: "googleworkspace_drive_comment_get",
            description: "Get a single Drive comment by ID.",
            properties: {
              file_id: string_prop("Drive file ID"),
              comment_id: string_prop("Comment ID"),
              include_deleted: boolean_prop("Include deleted comment content"),
              fields: string_prop("Response field mask (required by Drive; MadCP default if omitted)"),
            },
            required: %w[file_id comment_id],
          ) do |file_id:, comment_id:, include_deleted: nil, fields: nil|
            gws_api(
              "drive",
              ["comments"],
              "get",
              params: compact_hash(
                fileId: file_id,
                commentId: comment_id,
                includeDeleted: include_deleted,
                fields: drive_comment_fields(fields),
              ),
            )
          end

          define_tool(
            name: "googleworkspace_drive_comment_create",
            description: "Create a Drive comment on a file (shown in Docs All Comments). " \
                         "Optional anchor_line / quoted_text / anchor for best-effort anchoring; " \
                         "Google Workspace editors treat API-defined anchors as unanchored in the UI. " \
                         "Docs API has no suggestion mode — use comments for review notes, or " \
                         "googleworkspace_doc_batch_update for direct edits.",
            properties: {
              file_id: string_prop("Drive file ID (Docs document ID for Google Docs)"),
              content: string_prop("Plain-text comment body"),
              quoted_text: string_prop("Quoted file content the comment refers to (helps reviewers)"),
              quoted_mime_type: string_prop("MIME type for quoted_text (default text/plain)"),
              anchor_line: integer_prop(
                "Best-effort line number for Docs region anchor (rev=head). " \
                "Workspace UIs may still show the comment as unanchored.",
              ),
              anchor: {
                description: "Drive comment anchor as a JSON string, or an object that MadCP " \
                             "serializes to JSON (overrides anchor_line).",
              },
              fields: string_prop("Response field mask (required by Drive; MadCP default if omitted)"),
            },
            required: %w[file_id content],
            write: true,
          ) do |file_id:, content:, quoted_text: nil, quoted_mime_type: nil, anchor_line: nil, anchor: nil, fields: nil|
            gws_api(
              "drive",
              ["comments"],
              "create",
              params: compact_hash(fileId: file_id, fields: drive_comment_fields(fields)),
              body: drive_comment_body(
                content: content,
                anchor: anchor,
                anchor_line: anchor_line,
                quoted_text: quoted_text,
                quoted_mime_type: quoted_mime_type,
              ),
            )
          end

          define_tool(
            name: "googleworkspace_drive_comment_reply",
            description: "Reply to a Drive comment. Set action=resolve or reopen to close/reopen " \
                         "the discussion (resolve requires a reply).",
            properties: {
              file_id: string_prop("Drive file ID"),
              comment_id: string_prop("Parent comment ID"),
              content: string_prop("Plain-text reply (required unless action alone is enough)"),
              action: string_prop("Optional reply action: resolve or reopen"),
              fields: string_prop("Response field mask (MadCP default if omitted)"),
            },
            required: %w[file_id comment_id],
            write: true,
          ) do |file_id:, comment_id:, content: nil, action: nil, fields: nil|
            body = compact_hash(content: content, action: action)
            raise "content or action is required" if body.empty?

            gws_api(
              "drive",
              ["replies"],
              "create",
              params: compact_hash(
                fileId: file_id,
                commentId: comment_id,
                fields: drive_comment_fields(fields, reply: true),
              ),
              body: body,
            )
          end
        end

        def define_docs_tools
          define_tool(
            name: "googleworkspace_doc",
            description: "Read a Google Docs document.",
            properties: { document_id: string_prop("Google Docs document ID") },
            required: ["document_id"],
          ) do |document_id:|
            gws_api("docs", ["documents"], "get", params: { documentId: document_id })
          end

          define_tool(
            name: "googleworkspace_doc_create",
            description: "Create a Google Docs document.",
            properties: { title: string_prop("Document title") },
            required: ["title"],
            write: true,
          ) { |title:| gws_api("docs", ["documents"], "create", body: { title: title }) }

          define_tool(
            name: "googleworkspace_doc_append_text",
            description: "Append plain text to the end of a Google Docs document.",
            properties: {
              document_id: string_prop("Google Docs document ID"),
              text: string_prop("Text to append"),
            },
            required: %w[document_id text],
            write: true,
          ) do |document_id:, text:|
            gws_call do
              @client.helper(
                service: "docs",
                helper: "+write",
                flags: { document: document_id, text: text },
              )
            end
          end

          define_tool(
            name: "googleworkspace_doc_batch_update",
            description: "Apply rich-text and structural updates to a Google Docs document as " \
                         "direct edits. The public Docs API has no suggestion/review write mode; " \
                         "for marginal notes use googleworkspace_drive_comment_create instead.",
            properties: {
              document_id: string_prop("Google Docs document ID"),
              requests: {
                type: "array",
                items: { type: "object" },
                description: "Docs API batchUpdate requests (insertText, replaceAllText, styles, …)",
              },
            },
            required: %w[document_id requests],
            write: true,
          ) do |document_id:, requests:|
            gws_api(
              "docs",
              ["documents"],
              "batchUpdate",
              params: { documentId: document_id },
              body: { requests: Array(requests) },
            )
          end
        end

        def define_sheets_tools
          define_tool(
            name: "googleworkspace_spreadsheet",
            description: "Read spreadsheet metadata and optionally grid data.",
            properties: {
              spreadsheet_id: string_prop("Spreadsheet ID"),
              include_grid_data: boolean_prop("Include cell grid data"),
              fields: string_prop("Response field mask"),
            },
            required: ["spreadsheet_id"],
          ) do |spreadsheet_id:, include_grid_data: false, fields: nil|
            gws_api(
              "sheets",
              ["spreadsheets"],
              "get",
              params: compact_hash(
                spreadsheetId: spreadsheet_id,
                includeGridData: include_grid_data,
                fields: fields,
              ),
            )
          end

          define_tool(
            name: "googleworkspace_spreadsheet_create",
            description: "Create a Google Sheets spreadsheet.",
            properties: { title: string_prop("Spreadsheet title") },
            required: ["title"],
            write: true,
          ) do |title:|
            gws_api("sheets", ["spreadsheets"], "create", body: { properties: { title: title } })
          end

          define_tool(
            name: "googleworkspace_sheet_values",
            description: "Read values from a spreadsheet range.",
            properties: {
              spreadsheet_id: string_prop("Spreadsheet ID"),
              range: string_prop("A1 range, for example Sheet1!A1:D20"),
              value_render_option: string_prop("FORMATTED_VALUE, UNFORMATTED_VALUE, or FORMULA"),
            },
            required: %w[spreadsheet_id range],
          ) do |spreadsheet_id:, range:, value_render_option: nil|
            gws_api(
              "sheets",
              %w[spreadsheets values],
              "get",
              params: compact_hash(
                spreadsheetId: spreadsheet_id,
                range: range,
                valueRenderOption: value_render_option,
              ),
            )
          end

          define_sheet_value_writes

          define_tool(
            name: "googleworkspace_spreadsheet_batch_update",
            description: "Apply formatting, sheet, dimension, and structural spreadsheet updates.",
            properties: {
              spreadsheet_id: string_prop("Spreadsheet ID"),
              requests: { type: "array", items: { type: "object" }, description: "Sheets API batchUpdate requests" },
            },
            required: %w[spreadsheet_id requests],
            write: true,
          ) do |spreadsheet_id:, requests:|
            gws_api(
              "sheets",
              ["spreadsheets"],
              "batchUpdate",
              params: { spreadsheetId: spreadsheet_id },
              body: { requests: requests },
            )
          end
        end

        def define_sheet_value_writes
          %w[update append].each do |action|
            define_tool(
              name: "googleworkspace_sheet_values_#{action}",
              description: "#{action.capitalize} values in a spreadsheet range.",
              properties: {
                spreadsheet_id: string_prop("Spreadsheet ID"),
                range: string_prop("A1 range"),
                values: { type: "array", items: { type: "array" }, description: "Rows of cell values" },
                value_input_option: string_prop("RAW or USER_ENTERED"),
              },
              required: %w[spreadsheet_id range values],
              write: true,
            ) do |spreadsheet_id:, range:, values:, value_input_option: "USER_ENTERED"|
              gws_api(
                "sheets",
                %w[spreadsheets values],
                action,
                params: {
                  spreadsheetId: spreadsheet_id,
                  range: range,
                  valueInputOption: value_input_option,
                },
                body: { values: values },
              )
            end
          end

          define_tool(
            name: "googleworkspace_sheet_values_clear",
            description: "Clear values from a spreadsheet range.",
            properties: {
              spreadsheet_id: string_prop("Spreadsheet ID"),
              range: string_prop("A1 range"),
            },
            required: %w[spreadsheet_id range],
            write: true,
          ) do |spreadsheet_id:, range:|
            gws_api(
              "sheets",
              %w[spreadsheets values],
              "clear",
              params: { spreadsheetId: spreadsheet_id, range: range },
              body: {},
            )
          end
        end

        def define_generic_api_tools
          properties = {
            service: string_prop("gws service, for example sheets, docs, drive, gmail, or calendar"),
            resources: array_prop("Resource path segments, for example [\"spreadsheets\", \"values\"]"),
            method: string_prop("Discovery API method"),
            params: { type: "object", description: "URL/path/query parameters", additionalProperties: true },
            body: { type: "object", description: "Optional JSON request body", additionalProperties: true },
          }

          define_tool(
            name: "googleworkspace_api_read",
            description: "Call any clearly read-only gws Discovery API method.",
            properties: properties,
            required: %w[service resources method],
          ) do |service:, resources:, method:, params: {}, body: nil|
            unless SAFE_READ_METHODS.include?(method.to_s)
              raise "method is not classified as read-only; use googleworkspace_api_call with writes enabled"
            end
            raise "read-only calls cannot include a request body" unless body.nil? || body.empty?

            gws_api(service, resources, method, params: params)
          end

          define_tool(
            name: "googleworkspace_api_call",
            description: "Call any gws Workspace API method. Write-gated because dynamic methods may mutate data.",
            properties: properties,
            required: %w[service resources method],
            write: true,
          ) do |service:, resources:, method:, params: {}, body: nil|
            gws_api(service, resources, method, params: params, body: body)
          end
        end

        def gws_api(service, resources, method, params: nil, body: nil)
          params = with_drive_shared_support(service, resources, method, params)
          gws_call do
            @client.api(
              service: service,
              resources: resources,
              method: method,
              params: params,
              body: body,
            )
          end
        end

        def drive_comment_fields(fields, reply: false)
          value = fields.to_s.strip
          return value unless value.empty?

          reply ? DEFAULT_REPLY_FIELDS : DEFAULT_COMMENT_FIELDS
        end

        def drive_comment_body(content:, anchor: nil, anchor_line: nil, quoted_text: nil, quoted_mime_type: nil)
          body = { content: content }
          anchor_json = normalize_comment_anchor(anchor)
          if anchor_json
            body[:anchor] = anchor_json
          elsif !anchor_line.nil?
            body[:anchor] = JSON.generate(
              region: {
                kind: "drive#commentRegion",
                line: Integer(anchor_line),
                rev: "head",
              },
            )
          end

          quoted = quoted_text.to_s
          unless quoted.empty?
            mime = quoted_mime_type.to_s.strip
            body[:quotedFileContent] = {
              value: quoted,
              mimeType: mime.empty? ? "text/plain" : mime,
            }
          end

          body
        end

        def normalize_comment_anchor(anchor)
          return nil if anchor.nil?

          case anchor
          when String
            stripped = anchor.strip
            stripped.empty? ? nil : stripped
          when Hash
            JSON.generate(anchor)
          else
            JSON.generate(anchor)
          end
        end

        def with_drive_shared_support(service, resources, method, params)
          return params unless service.to_s == "drive"

          merged = (params || {}).to_h.transform_keys(&:to_s)
          resource_path = Array(resources).map(&:to_s)
          method_name = method.to_s

          # comments/replies do not accept supportsAllDrives
          return compact_hash(merged.transform_keys(&:to_sym)) if resource_path.intersect?(%w[comments replies])

          supports_methods = %w[
            get list create update copy delete export download
            batchGet createSubscription
          ]
          if supports_methods.include?(method_name) || resource_path.include?("files") || resource_path.include?("permissions") || resource_path.include?("changes")
            merged["supportsAllDrives"] = true unless merged.key?("supportsAllDrives")
          end

          if resource_path == ["files"] && method_name == "list"
            merged["includeItemsFromAllDrives"] = true unless merged.key?("includeItemsFromAllDrives")
            if merged["driveId"].to_s.empty?
              merged["corpora"] = "allDrives" if merged["corpora"].to_s.empty?
            else
              merged["corpora"] = "drive" if merged["corpora"].to_s.empty?
            end
          end

          compact_hash(merged.transform_keys(&:to_sym))
        end

        def gws_call
          text_response(yield)
        rescue CliError => e
          text_response("ERROR: #{e.message}")
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::GoogleWorkspace::Server)
