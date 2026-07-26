# frozen_string_literal: true

require "json"
require "securerandom"
require "sinatra/base"
require "uri"

module Madcp
  class App < Sinatra::Base
    def self.configured(config:, registry:, renderer:)
      providers = registry.all.to_h do |integration|
        [integration.id, OAuthProvider.new(config: config, integration: integration)]
      end
      oauth_retrieval_states = {}
      oauth_retrieval_mutex = Mutex.new

      Class.new(self) do
        set :environment, :production
        set :server, :puma
        set :bind, config.host
        set :port, config.port
        set :logging, true
        set :show_exceptions, false
        set :host_authorization, permitted_hosts: []
        set :oauth_retrieval_states, oauth_retrieval_states

        define_method(:config) { config }
        define_method(:registry) { registry }
        define_method(:renderer) { renderer }
        define_method(:providers) { providers }
        define_method(:oauth_retrieval_states) { oauth_retrieval_states }
        define_method(:oauth_retrieval_mutex) { oauth_retrieval_mutex }
      end
    end

    helpers do
      def json(payload, status_code = 200)
        status status_code
        content_type :json
        JSON.generate(payload)
      end

      def parse_json_body
        raw = request.body.read
        return {} if raw.empty?

        parsed = JSON.parse(raw)
        halt 400, json({ error: "body must be a JSON object" }, 400) unless parsed.is_a?(Hash)
        parsed
      rescue JSON::ParserError
        halt 400, json({ error: "invalid JSON" }, 400)
      end

      def integration
        registry.fetch(params[:server_id])
      rescue KeyError => e
        halt 404, json({ error: e.message }, 404)
      end

      def provider
        providers.fetch(params[:server_id])
      end

      def bearer_token
        header = request.env["HTTP_AUTHORIZATION"].to_s
        header.start_with?("Bearer ") ? header.delete_prefix("Bearer ") : nil
      end

      def authorize_mcp!
        return if provider.load_access_token(bearer_token)

        metadata = "#{config.public_url}/.well-known/oauth-protected-resource/servers/#{integration.id}/mcp"
        headers["WWW-Authenticate"] =
          %(Bearer error="invalid_token", resource_metadata="#{metadata}")
        halt 401, json({ error: "invalid_token", error_description: "Authentication required" }, 401)
      end

      def verify_transport!
        host = request.env["HTTP_HOST"].to_s
        bare = host.start_with?("[") ? host : host.split(":").first
        halt 421, "Invalid Host header" unless config.allowed_hosts.include?(host) ||
                                                config.allowed_hosts.include?(bare)

        origin = request.env["HTTP_ORIGIN"].to_s
        halt 403, "Invalid Origin header" if !origin.empty? &&
                                             !config.allowed_origins.include?(origin)
      end

      def oauth_error(error)
        json(error.payload, error.status)
      end

      def require_oauth_token_retrieval!
        halt 404, json({ error: "OAuth token retrieval is not available for this integration" }, 404) unless integration.oauth_token_retrieval?
      end

      def oauth_callback_url
        "#{config.public_url}/servers/#{integration.id}/oauth_callback"
      end

      def consume_oauth_retrieval_state(state)
        oauth_retrieval_mutex.synchronize do
          data = oauth_retrieval_states.delete(state.to_s)
          return nil unless data
          return nil unless data[:server_id] == integration.id
          return nil if data[:expires_at] < Time.now.to_i

          data
        end
      end

      def oauth_query_params
        URI.decode_www_form(request.query_string.to_s).each_with_object({}) do |(key, value), result|
          if result.key?(key)
            result[key] = Array(result[key]) << value
          else
            result[key] = value
          end
        end
      end

      def redact_oauth_secrets(value)
        case value
        when Hash
          value.to_h do |key, item|
            redacted = key.to_s.casecmp?("client_secret") ? "[REDACTED]" : redact_oauth_secrets(item)
            [key, redacted]
          end
        when Array
          value.map { |item| redact_oauth_secrets(item) }
        else
          value
        end
      end

      def integration_locals(integration, extra = {})
        {
          title: integration.display_name,
          integration: integration,
          public_url: config.public_url,
          repo_url: "https://github.com/magnum/madcp",
        }.merge(extra)
      end

      def response_payload(response)
        return response.to_h if response.respond_to?(:to_h)

        JSON.parse(response.to_json)
      rescue JSON::ParserError, NoMethodError
        { content: [{ type: "text", text: response.to_s }] }
      end
    end

    before do
      verify_transport! if request.path_info.include?("/mcp") ||
                           request.path_info.match?(%r{/servers/[^/]+/tools/})
    end

    get "/" do
      redirect "/servers/", 302
    end

    get ["/servers", "/servers/"] do
      wants_json = request.env["HTTP_ACCEPT"].to_s.include?("application/json")
      if wants_json || params["format"] == "json"
        json(servers: registry.catalog)
      else
        content_type :html
        renderer.page(
          "servers",
          title: "MADCP integrations",
          integrations: registry.all,
          public_url: config.public_url,
          repo_url: "https://github.com/magnum/madcp",
        )
      end
    end

    get "/healthz" do
      json(
        status: "ok",
        integrations: registry.all.to_h { |item| [item.id, item.auth_status] },
      )
    end

    get "/servers/:server_id/tools" do
      json(
        server_id: integration.id,
        allow_write_methods: integration.allow_write_methods?,
        tools: integration.tool_catalog,
      )
    end

    post "/servers/:server_id/tools/:tool" do
      authorize_mcp!
      result = integration.call_tool(params[:tool], parse_json_body)
      json(response_payload(result))
    rescue KeyError => e
      json({ error: e.message }, 404)
    rescue SecurityError => e
      json({ error: e.message }, 403)
    end

    post "/servers/:server_id/mcp" do
      authorize_mcp!
      body = request.body.read
      halt 400, json({ error: "empty request body" }, 400) if body.empty?

      result = integration.mcp_server.handle_json(body)
      if result.nil?
        status 202
        ""
      else
        content_type :json
        result
      end
    end

    get("/servers/:server_id/mcp") { halt 405, { "Allow" => "POST" }, "" }
    delete("/servers/:server_id/mcp") { halt 405, { "Allow" => "POST" }, "" }

    # OAuth discovery aliases for path-based MCP resources.
    get "/.well-known/oauth-protected-resource/servers/:server_id/mcp" do
      headers["Access-Control-Allow-Origin"] = "*"
      json(provider.protected_resource_metadata)
    end

    get "/.well-known/oauth-authorization-server/servers/:server_id" do
      headers["Access-Control-Allow-Origin"] = "*"
      json(provider.authorization_server_metadata)
    end

    get "/.well-known/oauth-authorization-server/servers/:server_id/mcp" do
      headers["Access-Control-Allow-Origin"] = "*"
      json(provider.authorization_server_metadata)
    end

    get "/servers/:server_id/.well-known/oauth-authorization-server" do
      headers["Access-Control-Allow-Origin"] = "*"
      json(provider.authorization_server_metadata)
    end

    get "/servers/:server_id/auth" do
      state = params["state"].to_s
      if !state.empty? && !provider.valid_state?(state)
        halt 400, json({ error: "invalid state" }, 400)
      end

      content_type :html
      renderer.page(
        "auth",
        **integration_locals(
          integration,
          state: state.empty? ? nil : state,
          error: nil,
          message: nil,
        ),
      )
    end

    post "/servers/:server_id/auth/credentials" do
      provider.verify_operator!(params["username"], params["password"])
      integration.apply_credentials(params)
      content_type :html
      renderer.page(
        "auth",
        **integration_locals(
          integration,
          state: nil,
          error: nil,
          message: "Credentials updated.",
        ),
      )
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    rescue StandardError => e
      status 400
      content_type :html
      renderer.page(
        "auth",
        **integration_locals(integration, state: nil, error: e.message, message: nil),
      )
    end

    post "/servers/:server_id/oauth" do
      require_oauth_token_retrieval!
      provider.verify_operator!(params["username"], params["password"])
      state = SecureRandom.urlsafe_base64(32)
      oauth_retrieval_mutex.synchronize do
        oauth_retrieval_states.delete_if { |_, data| data[:expires_at] < Time.now.to_i }
        oauth_retrieval_states[state] = {
          server_id: integration.id,
          expires_at: Time.now.to_i + 300,
        }
      end
      result = integration.oauth_call(callback_url: oauth_callback_url, state: state)
      authorization_url = result[:authorization_url] || result["authorization_url"]
      raise "integration did not return an authorization_url" if authorization_url.to_s.empty?

      redirect authorization_url, 302
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    rescue StandardError => e
      halt 400, json({ error: e.message }, 400)
    end

    get "/servers/:server_id/oauth_callback" do
      headers["Cache-Control"] = "no-store"
      headers["Referrer-Policy"] = "no-referrer"
      require_oauth_token_retrieval!
      callback_params = oauth_query_params
      state = callback_params["state"]
      halt 400, json({ error: "invalid, expired, or already used OAuth state" }, 400) unless consume_oauth_retrieval_state(state)

      result = nil
      if callback_params["code"].is_a?(String) && !callback_params["code"].empty?
        result = integration.oauth_exchange(
          callback_url: oauth_callback_url,
          params: callback_params,
        )
      end
      content_type :html
      renderer.page(
        "oauth_result",
        **integration_locals(
          integration,
          callback_url: oauth_callback_url,
          oauth_params: redact_oauth_secrets(callback_params),
          oauth_result: redact_oauth_secrets(result),
        ),
      )
    rescue StandardError => e
      status 400
      content_type :html
      renderer.page(
        "oauth_result",
        **integration_locals(
          integration,
          callback_url: oauth_callback_url,
          oauth_params: redact_oauth_secrets(oauth_query_params),
          oauth_result: { error: e.message },
        ),
      )
    end

    get "/servers/:server_id/auth/authorize" do
      redirect provider.start_authorization(params), 302
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    end

    post "/servers/:server_id/auth/callback" do
      state = params["state"].to_s
      provider.verify_operator!(params["username"], params["password"])
      integration.apply_credentials(params)
      redirect provider.authorize_login(
        username: params["username"],
        password: params["password"],
        state: state,
      ), 302
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    rescue StandardError => e
      status 400
      content_type :html
      renderer.page(
        "auth",
        **integration_locals(integration, state: state, error: e.message, message: nil),
      )
    end

    post "/servers/:server_id/auth/register" do
      json(provider.register_client(parse_json_body), 201)
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    end

    post "/servers/:server_id/auth/token" do
      json(provider.token_request(params))
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    end

    post "/servers/:server_id/auth/revoke" do
      provider.revoke_token(params["token"])
      json({})
    end

    get "/servers/:server_id/auth/logout" do
      content_type :html
      renderer.page(
        "logout",
        **integration_locals(integration, error: nil, message: nil),
      )
    end

    post "/servers/:server_id/auth/logout" do
      provider.verify_operator!(params["username"], params["password"])
      count = provider.revoke_all!
      integration.clear_credentials! if params["clear_integration"] == "1"
      content_type :html
      renderer.page(
        "logout",
        **integration_locals(
          integration,
          error: nil,
          message: "Revoked #{count} OAuth token(s).",
        ),
      )
    rescue OAuthProvider::OAuthError => e
      status e.status
      content_type :html
      renderer.page(
        "logout",
        **integration_locals(integration, error: e.message, message: nil),
      )
    end
  end
end
