# frozen_string_literal: true

require "fileutils"
require_relative "fattureincloud_client"

module Madcp
  module Servers
    module FattureInCloud
      class Server < Integration
        server_id "fattureincloud"
        display_name "Fatture in Cloud"
        description "Companies, archive documents, invoices, clients, and suppliers through the Fatture in Cloud v2 API."
        version "0.1.0"
        oauth_token_retrieval true

        DEFAULT_SCOPES = "entity.clients:r entity.suppliers:r issued_documents.invoices:r archive:r"
        LIST_PROPERTIES = {
          fields: { type: "string", description: "Comma-separated response fields" },
          fieldset: { type: "string", description: "Named response fieldset" },
          sort: { type: "string", description: "Sort expression" },
          page: { type: "integer", description: "Page number" },
          per_page: { type: "integer", description: "Items per page" },
          q: { type: "string", description: "API search/filter query" },
        }.freeze

        def initialize(config:)
          super
          @client = Client.new
        end

        def instructions
          "Use Fatture in Cloud tools to read company accounting data. " \
            "All mutations accept a raw JSON object and remain disabled unless write methods are enabled."
        end

        def auth_help_content
          {
            title: "Authorize Fatture in Cloud",
            description: "The simplest option is the OAuth flow available in this form. " \
                         "MADCP will open Fatture in Cloud and show the returned access token.",
            steps: [
              "Configure FATTUREINCLOUD_CLIENT_ID and FATTUREINCLOUD_CLIENT_SECRET.",
              "Register the callback URL shown below in the Fatture in Cloud application.",
              "Enter the MADCP operator credentials, then choose Retrieve OAuth token.",
              "On the callback page, confirm the token was saved (or paste it once) and return here.",
            ],
            commands: [],
            note: "MADCP stores the full OAuth token response (including refresh_token) under " \
                  "data/fattureincloud/oauth_token.json. The default company ID is optional.",
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

        def auth_status
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
          old = credential_env_keys.to_h { |key| [key, ENV[key]] }
          updates = {
            "FATTUREINCLOUD_TOKEN" => token,
            "FATTUREINCLOUD_COMPANY_ID" => company_id,
          }
          persist_credentials!(updates)
          @client = Client.new
          return true if auth_status[:authenticated]

          persist_credentials!(old)
          @client = Client.new
          raise "Fatture in Cloud token was rejected"
        ensure
          token = nil
        end

        def apply_oauth_result!(result)
          body = oauth_result_body(result)
          access_token = Madcp.sanitize_env_value(body["access_token"] || body[:access_token])
          raise "OAuth response did not include an access_token" if access_token.empty?

          persist_oauth_token_payload!(body)
          persist_credentials!(
            "FATTUREINCLOUD_TOKEN" => access_token,
            "FATTUREINCLOUD_REFRESH_TOKEN" => Madcp.sanitize_env_value(
              body["refresh_token"] || body[:refresh_token],
            ),
          )
          @client = Client.new
          raise "Fatture in Cloud token was rejected" unless auth_status[:authenticated]

          true
        end

        def apply_oauth_token_paste!(access_token:, token_json: nil)
          token = Madcp.sanitize_env_value(access_token)
          raise "Access token is required" if token.empty?

          payload = parse_token_json_paste(token_json)
          payload = payload.merge("access_token" => token) if payload
          payload ||= { "access_token" => token }

          persist_oauth_token_payload!(payload)
          persist_credentials!(
            "FATTUREINCLOUD_TOKEN" => token,
            "FATTUREINCLOUD_REFRESH_TOKEN" => Madcp.sanitize_env_value(
              payload["refresh_token"] || payload[:refresh_token],
            ),
          )
          @client = Client.new
          raise "Fatture in Cloud token was rejected" unless auth_status[:authenticated]

          true
        end

        def clear_credentials!
          File.delete(oauth_token_path) if File.file?(oauth_token_path)
          persist_credentials!(
            "FATTUREINCLOUD_TOKEN" => nil,
            "FATTUREINCLOUD_COMPANY_ID" => nil,
            "FATTUREINCLOUD_REFRESH_TOKEN" => nil,
          )
          @client = Client.new
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

        def oauth_exchange(callback_url:, params:)
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

        private

        def oauth_token_path
          File.join(data_dir, "oauth_token.json")
        end

        def oauth_result_body(result)
          raise "Empty OAuth token response" if result.nil?

          body = result.is_a?(Hash) ? (result[:body] || result["body"] || result) : nil
          raise "OAuth token response body is missing" unless body.is_a?(Hash)

          status = result[:status] || result["status"]
          if status && !status.to_i.between?(200, 299)
            raise "OAuth token exchange failed with status #{status}"
          end

          body
        end

        def persist_oauth_token_payload!(payload)
          raise "OAuth token payload must be a JSON object" unless payload.is_a?(Hash)

          FileUtils.mkdir_p(File.dirname(oauth_token_path))
          File.write(oauth_token_path, JSON.pretty_generate(payload) + "\n", perm: 0o600)
        end

        def parse_token_json_paste(raw)
          text = raw.to_s.strip
          return nil if text.empty?

          parsed = JSON.parse(text)
          raise "token JSON must be an object" unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError => e
          raise "Invalid token JSON: #{e.message}"
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

        def api_response(result)
          text_response(JSON.pretty_generate(result))
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::FattureInCloud::Server)
