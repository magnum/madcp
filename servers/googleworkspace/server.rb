# frozen_string_literal: true

require_relative "googleworkspace_client"

module Madcp
  module Servers
    module GoogleWorkspace
      class Server < Integration
        server_id "googleworkspace"
        display_name "Google Workspace"
        description "Google Docs, Sheets, Drive, and every Workspace API exposed dynamically by the gws CLI."
        version "0.1.0"

        SAFE_READ_METHODS = %w[get list search lookup query export download batchGet].freeze

        def initialize(config:)
          super
          @client = Client.new
        end

        def instructions
          "Use typed Google Docs and Sheets tools for common document editing. " \
            "Use googleworkspace_discover and googleworkspace_schema to inspect any other Workspace API. " \
            "The unrestricted generic API tool is write-gated."
        end

        def auth_fields
          [
            {
              name: "googleworkspace_token",
              label: "Google OAuth access token",
              type: "password",
              required: false,
              help: "Optional short-lived token. GOOGLE_WORKSPACE_CLI_TOKEN has highest priority.",
            },
            {
              name: "googleworkspace_credentials_json",
              label: "Exported gws credentials JSON",
              type: "textarea",
              required: false,
              help: "Recommended for Docker: gws auth export --unmasked > credentials.json",
            },
            {
              name: "googleworkspace_project_id",
              label: "Google Cloud project ID",
              type: "text",
              required: false,
              help: "Optional quota/billing project used by gws helpers.",
            },
          ]
        end

        def auth_status
          raw = @client.auth_status
          parsed = JSON.parse(raw)
          data = parsed["data"] || parsed
          credential_source = data["credential_source"].to_s.downcase
          auth_method = data["auth_method"].to_s.downcase
          authenticated = data["authenticated"] == true ||
                          data["token_valid"] == true ||
                          (!credential_source.empty? && credential_source != "none") ||
                          (!auth_method.empty? && auth_method != "none") ||
                          %w[authenticated success ok].include?(data["status"].to_s.downcase)
          {
            authenticated: authenticated,
            auth_method: data["auth_method"],
            credential_source: data["credential_source"],
            token_valid: data["token_valid"],
            project_id: ENV["GOOGLE_WORKSPACE_PROJECT_ID"],
            credentials_file: ENV["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"],
          }
        rescue StandardError => e
          {
            authenticated: false,
            project_id: ENV["GOOGLE_WORKSPACE_PROJECT_ID"],
            error: e.message,
          }
        end

        def apply_credentials(params)
          old_env = credential_env_keys.to_h { |key| [key, ENV[key]] }
          old_credentials = File.binread(credentials_path) if File.file?(credentials_path)
          token = params["googleworkspace_token"].to_s.strip
          credentials_json = params["googleworkspace_credentials_json"].to_s.strip
          project_id = params["googleworkspace_project_id"].to_s.strip

          updates = {}
          updates["GOOGLE_WORKSPACE_CLI_TOKEN"] = token unless token.empty?
          updates["GOOGLE_WORKSPACE_PROJECT_ID"] = project_id unless project_id.empty?
          unless credentials_json.empty?
            parsed = JSON.parse(credentials_json)
            raise "Google Workspace credentials must be a JSON object" unless parsed.is_a?(Hash)

            File.write(credentials_path, JSON.pretty_generate(parsed) + "\n", perm: 0o600)
            updates["GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE"] = credentials_path
          end
          persist_credentials!(updates)
          @client = Client.new
          raise "Google Workspace CLI is not authenticated" unless auth_status[:authenticated]

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
          message = if e.is_a?(JSON::ParserError)
                      "Invalid Google Workspace credentials JSON: #{e.message}"
                    else
                      e.message
                    end
          raise message
        ensure
          token = nil
          credentials_json = nil
        end

        def clear_credentials!
          File.delete(credentials_path) if File.file?(credentials_path)
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
            description: "List or search Google Drive files.",
            properties: {
              query: string_prop("Drive q expression"),
              page_size: integer_prop("Maximum files"),
              page_token: string_prop("Pagination token"),
              order_by: string_prop("Drive orderBy expression"),
              fields: string_prop("Response field mask"),
            },
          ) do |query: nil, page_size: 50, page_token: nil, order_by: nil, fields: nil|
            params = compact_hash(
              q: query,
              pageSize: page_size,
              pageToken: page_token,
              orderBy: order_by,
              fields: fields,
            )
            gws_api("drive", ["files"], "list", params: params)
          end

          define_tool(
            name: "googleworkspace_drive_file",
            description: "Get Google Drive file metadata.",
            properties: {
              file_id: string_prop("Drive file ID"),
              fields: string_prop("Response field mask"),
            },
            required: ["file_id"],
          ) do |file_id:, fields: nil|
            gws_api("drive", ["files"], "get", params: compact_hash(fileId: file_id, fields: fields))
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
            description: "Apply rich-text and structural updates to a Google Docs document.",
            properties: {
              document_id: string_prop("Google Docs document ID"),
              requests: { type: "array", items: { type: "object" }, description: "Docs API batchUpdate requests" },
            },
            required: %w[document_id requests],
            write: true,
          ) do |document_id:, requests:|
            gws_api(
              "docs",
              ["documents"],
              "batchUpdate",
              params: { documentId: document_id },
              body: { requests: requests },
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

        def gws_call
          text_response(yield)
        rescue CliError => e
          text_response("ERROR: #{e.message}")
        end

        def compact_hash(values)
          values.reject { |_, value| value.nil? || value == "" }
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::GoogleWorkspace::Server)
