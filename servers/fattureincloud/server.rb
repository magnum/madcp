# frozen_string_literal: true

require "fileutils"
require_relative "fattureincloud_client"

module Madcp
  module Servers
    module FattureInCloud
      class Server < ::McpServer
        server_id "fattureincloud"
        display_name "Fatture in Cloud"
        description "Companies, archive documents, invoices, self-invoices, clients, and suppliers through the Fatture in Cloud v2 API."
        version "0.1.0"
        oauth_token_retrieval true

        # :a = full write on that resource (create/modify/delete). :r = read-only.
        # MadCP write tools still require FATTUREINCLOUD_ALLOW_WRITE=true.
        # Override with FATTUREINCLOUD_OAUTH_SCOPES if needed; re-authorize after changes.
        DEFAULT_SCOPES = [
          "entity.clients:a",
          "entity.suppliers:a",
          "issued_documents.invoices:a",
          "issued_documents.credit_notes:a",
          "issued_documents.quotes:a",
          "issued_documents.proformas:a",
          "issued_documents.self_invoices:a",
          "received_documents:r",
          "situation:r",
          "taxes:r",
          "cashbook:r",
          "calendar:r",
          "archive:a",
        ].join(" ")
        LIST_PROPERTIES = {
          fields: { type: "string", description: "Comma-separated response fields" },
          fieldset: { type: "string", description: "Named response fieldset" },
          sort: { type: "string", description: "Sort expression" },
          page: { type: "integer", description: "Page number" },
          per_page: { type: "integer", description: "Items per page" },
          q: { type: "string", description: "API search/filter query" },
        }.freeze
        after_initialize :ensure_runtime_client
        after_find :ensure_runtime_client

        def ensure_runtime_client
          return if defined?(@client) && @client
          replace_client! if respond_to?(:replace_client!, true)
        end

        def instructions
          "Use Fatture in Cloud tools to read company accounting data. " \
            "Expired access tokens are refreshed automatically when FATTUREINCLOUD_REFRESH_TOKEN " \
            "and CLIENT_ID/SECRET are configured. " \
            "All mutations accept a raw JSON object and remain disabled unless write methods are enabled."
        end

        def auth_help_content
          {
            title: "Authorize Fatture in Cloud",
            description: "The simplest option is the OAuth flow available in this form. " \
                         "MadCP will open Fatture in Cloud and show the returned access token.",
            steps: [
              "Configure FATTUREINCLOUD_CLIENT_ID and FATTUREINCLOUD_CLIENT_SECRET.",
              "Register the callback URL shown below in the Fatture in Cloud application.",
              "Choose Retrieve OAuth token (you are already signed in with MadCP Basic Auth).",
              "On the callback page, confirm the token was saved (or paste it once) and return here.",
            ],
            commands: [],
            note: "MadCP stores the full OAuth token response (including refresh_token) under " \
                  "data/fattureincloud/oauth_token.json. Access tokens expire in ~24h; MadCP " \
                  "refreshes them automatically using the refresh token (valid ~1 year). " \
                  "The default company ID is optional.",
          }
        end

        def auth_fields
          [
            {
              name: "fattureincloud_token",
              label: "Fatture in Cloud access token",
              type: "password",
              required: false,
              help: "Paste an OAuth access token, or use Retrieve OAuth token below.",
              env: "FATTUREINCLOUD_TOKEN",
            },
            {
              name: "fattureincloud_company_id",
              label: "Default company ID (optional)",
              type: "text",
              required: false,
              help: "Used when a company-scoped tool omits company_id.",
              env: "FATTUREINCLOUD_COMPANY_ID",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def fetch_auth_status
          result = @client.get("/user/companies")
          {
            authenticated: result[:status].between?(200, 299),
            company_id: ENV["FATTUREINCLOUD_COMPANY_ID"],
          }
        rescue StandardError => e
          {
            authenticated: false,
            company_id: ENV["FATTUREINCLOUD_COMPANY_ID"],
            error: e.message,
          }
        end

        def apply_credentials(params)
          token = Madcp.sanitize_env_value(params["fattureincloud_token"])
          company_id = Madcp.sanitize_env_value(params["fattureincloud_company_id"])
          apply_credentials_probe!(
            {
              "FATTUREINCLOUD_TOKEN" => token,
              "FATTUREINCLOUD_COMPANY_ID" => company_id,
            },
            rejection_message: "Fatture in Cloud token was rejected",
          )
        ensure
          token = nil
        end

        def clear_credentials!
          clear_oauth_token_file!
          persist_credentials!(
            "FATTUREINCLOUD_TOKEN" => nil,
            "FATTUREINCLOUD_COMPANY_ID" => nil,
            "FATTUREINCLOUD_REFRESH_TOKEN" => nil,
          )
          replace_client!
        end

        def oauth_call(callback_url:, state:)
          client_id = ENV["FATTUREINCLOUD_CLIENT_ID"].to_s
          raise "FATTUREINCLOUD_CLIENT_ID is required" if client_id.empty?

          query = {
            response_type: "code",
            client_id: client_id,
            redirect_uri: callback_url,
            scope: ENV.fetch("FATTUREINCLOUD_OAUTH_SCOPES", DEFAULT_SCOPES),
            state: state,
          }
          { authorization_url: "https://api-v2.fattureincloud.it/oauth/authorize?#{URI.encode_www_form(query)}" }
        end

        def oauth_exchange(callback_url:, params:, state_data: nil)
          client_id = ENV["FATTUREINCLOUD_CLIENT_ID"].to_s
          client_secret = ENV["FATTUREINCLOUD_CLIENT_SECRET"].to_s
          raise "FATTUREINCLOUD_CLIENT_ID is required" if client_id.empty?
          raise "FATTUREINCLOUD_CLIENT_SECRET is required" if client_secret.empty?
          raise "OAuth callback did not include a code" if params["code"].to_s.empty?

          @client.request(
            :post,
            "/oauth/token",
            bearer: false,
            raise_on_error: false,
            body: {
              grant_type: "authorization_code",
              client_id: client_id,
              client_secret: client_secret,
              redirect_uri: callback_url,
              code: params["code"],
            },
          )
        end

        def configure_tools
          define_company_tools
          define_collection_tools("archive", "/archive", "archive document")
          define_issued_document_tools
          define_collection_tools("clients", "/entities/clients", "client")
          define_collection_tools("suppliers", "/entities/suppliers", "supplier")
        end

        protected

        def credential_env_keys
          %w[
            FATTUREINCLOUD_TOKEN
            FATTUREINCLOUD_COMPANY_ID
            FATTUREINCLOUD_REFRESH_TOKEN
          ]
        end

        def oauth_access_env = "FATTUREINCLOUD_TOKEN"
        def oauth_refresh_env = "FATTUREINCLOUD_REFRESH_TOKEN"

        def replace_client!
          @client = build_client
        end

        private

        def build_client
          Client.new(on_token_refresh: method(:persist_refreshed_token!))
        end

        def persist_refreshed_token!(access_token:, refresh_token:, body:)
          persist_refreshed_oauth_token!(
            access_token: access_token,
            refresh_token: refresh_token,
            body: body,
          )
        end

        def define_company_tools
          define_tool(
            name: "fattureincloud_companies",
            description: "List companies available to the authenticated user.",
          ) { api_response(@client.get("/user/companies")) }

          define_tool(
            name: "fattureincloud_company_info",
            description: "Get information about a company.",
            properties: company_property,
          ) do |company_id: nil|
            api_response(@client.get(company_path(company_id, "/company/info")))
          end
        end

        def define_issued_document_tools
          properties = { company_id: company_id_prop, type: string_prop("Document type, default: invoice"), **LIST_PROPERTIES }
          define_tool(
            name: "fattureincloud_issued_documents",
            description: "List issued documents. The type defaults to invoice.",
            properties: properties,
          ) do |company_id: nil, type: "invoice", fields: nil, fieldset: nil, sort: nil, page: nil, per_page: nil, q: nil|
            query = list_query(fields:, fieldset:, sort:, page:, per_page:, q:).merge(type: type || "invoice")
            api_response(@client.get(company_path(company_id, "/issued_documents"), query: query))
          end
          define_get_and_mutations("issued_document", "/issued_documents", "issued document")
        end

        def define_collection_tools(plural_name, api_path, label)
          define_tool(
            name: "fattureincloud_#{plural_name}",
            description: "List #{plural_name.tr("_", " ")}.",
            properties: { company_id: company_id_prop, **LIST_PROPERTIES },
          ) do |company_id: nil, fields: nil, fieldset: nil, sort: nil, page: nil, per_page: nil, q: nil|
            api_response(
              @client.get(
                company_path(company_id, api_path),
                query: list_query(fields:, fieldset:, sort:, page:, per_page:, q:),
              ),
            )
          end
          singular = plural_name == "archive" ? "archive_document" : plural_name.sub(/s\z/, "")
          define_get_and_mutations(singular, api_path, label)
        end

        def define_get_and_mutations(tool_name, api_path, label)
          define_tool(
            name: "fattureincloud_#{tool_name}",
            description: "Get one #{label}.",
            properties: { company_id: company_id_prop, id: string_prop("#{label.capitalize} ID") },
            required: ["id"],
          ) do |id:, company_id: nil|
            api_response(@client.get(company_path(company_id, "#{api_path}/#{path_id(id)}")))
          end

          payload_properties = {
            company_id: company_id_prop,
            payload: { type: "object", description: "Raw Fatture in Cloud API JSON object", additionalProperties: true },
          }
          define_tool(
            name: "fattureincloud_#{tool_name}_create",
            description: "Create a #{label} from a raw API payload.",
            properties: payload_properties,
            required: ["payload"],
            write: true,
          ) do |payload:, company_id: nil|
            api_response(@client.post(company_path(company_id, api_path), body: require_payload(payload)))
          end

          define_tool(
            name: "fattureincloud_#{tool_name}_modify",
            description: "Modify a #{label} using a raw API payload.",
            properties: payload_properties.merge(id: string_prop("#{label.capitalize} ID")),
            required: %w[id payload],
            write: true,
          ) do |id:, payload:, company_id: nil|
            api_response(@client.put(company_path(company_id, "#{api_path}/#{path_id(id)}"), body: require_payload(payload)))
          end

          define_tool(
            name: "fattureincloud_#{tool_name}_delete",
            description: "Delete a #{label}; optionally forward a raw API payload.",
            properties: payload_properties.merge(id: string_prop("#{label.capitalize} ID")),
            required: ["id"],
            write: true,
          ) do |id:, payload: nil, company_id: nil|
            api_response(@client.delete(company_path(company_id, "#{api_path}/#{path_id(id)}"), body: optional_payload(payload)))
          end
        end

        def company_property = { company_id: company_id_prop }
        def company_id_prop = string_prop("Company ID; defaults to the persisted company ID")

        def company_path(company_id, suffix)
          id = company_id.to_s.strip
          id = ENV["FATTUREINCLOUD_COMPANY_ID"].to_s.strip if id.empty?
          raise "company_id is required; provide it or configure FATTUREINCLOUD_COMPANY_ID" if id.empty?

          "/c/#{path_id(id)}#{suffix}"
        end

        def path_id(value)
          URI.encode_www_form_component(value.to_s)
        end

        def list_query(fields:, fieldset:, sort:, page:, per_page:, q:)
          { fields: fields, fieldset: fieldset, sort: sort, page: page, per_page: per_page, q: q }
        end

        def require_payload(payload)
          raise "payload must be a JSON object" unless payload.is_a?(Hash)

          payload
        end

        def optional_payload(payload)
          payload.nil? ? nil : require_payload(payload)
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::FattureInCloud::Server)
