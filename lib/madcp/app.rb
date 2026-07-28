# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
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
      request_logger = RequestLogger.new(
        path: config.request_log_path,
        io: $stdout,
        max_chars: config.request_log_max_chars,
      )

      Class.new(self) do
        set :environment, :production
        set :server, :puma
        set :bind, config.host
        set :port, config.port
        set :logging, false
        set :show_exceptions, false
        set :host_authorization, permitted_hosts: []
        set :oauth_retrieval_states, oauth_retrieval_states

        define_method(:config) { config }
        define_method(:registry) { registry }
        define_method(:renderer) { renderer }
        define_method(:providers) { providers }
        define_method(:oauth_retrieval_states) { oauth_retrieval_states }
        define_method(:oauth_retrieval_mutex) { oauth_retrieval_mutex }
        define_method(:request_logger) { request_logger }
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

      def operator_ui_request?
        path = request.path_info
        return false if path == "/logout"
        return true if path == "/" || path == "/servers" || path == "/servers/"
        return true if path.match?(%r{\A/servers/[^/]+/oauth(_callback)?\z})
        return false unless path.match?(%r{\A/servers/[^/]+/auth(?:/|\z)})

        !path.match?(%r{/auth/(register|token|revoke|authorize)\z})
      end

      def require_operator_basic_auth!
        header = request.env["HTTP_AUTHORIZATION"].to_s
        if header.start_with?("Basic ")
          decoded = Base64.decode64(header.delete_prefix("Basic ")).force_encoding("UTF-8")
          username, password = decoded.split(":", 2)
          if secure_basic_equals(username, config.auth_username) &&
             secure_basic_equals(password, config.auth_password)
            return
          end
        end

        headers["WWW-Authenticate"] = 'Basic realm="MadCP"'
        halt 401, "Authentication required"
      end

      def secure_basic_equals(a, b)
        OpenSSL.fixed_length_secure_compare(
          Digest::SHA256.digest(a.to_s),
          Digest::SHA256.digest(b.to_s),
        )
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

      OAUTH_REDACT_KEYS = %w[client_secret code_verifier].freeze

      def redact_oauth_secrets(value)
        case value
        when Hash
          value.to_h do |key, item|
            redacted = OAUTH_REDACT_KEYS.any? { |name| key.to_s.casecmp?(name) } ?
              "[REDACTED]" :
              redact_oauth_secrets(item)
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

      def capture_request_body
        input = request.body
        return "" unless input

        data = input.read
        input.rewind if input.respond_to?(:rewind)
        data.to_s
      rescue StandardError
        ""
      end

      def log_request!
        path = request.fullpath.to_s
        return if path == "/healthz" || path.start_with?("/healthz?")

        started = env["madcp.request_started_at"]
        duration_ms =
          if started
            ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          else
            0
          end

        request_logger.log(
          ip: request.ip,
          method: request.request_method,
          path: path,
          status: response.status,
          duration_ms: duration_ms,
          user_agent: request.user_agent,
          request_body: env["madcp.request_body"],
        )
      rescue StandardError => e
        warn("[madcp] request logging skipped: #{e.class}: #{e.message}")
      end
    end

    before do
      env["madcp.request_started_at"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      env["madcp.request_body"] = capture_request_body
      require_operator_basic_auth! if operator_ui_request?
      verify_transport! if request.path_info.include?("/mcp") ||
                           request.path_info.match?(%r{/servers/[^/]+/tools/})
    end

    after do
      log_request!
    end

    get "/" do
      redirect "/servers/", 302
    end

    # HTTP Basic Auth has no real server-side session. Returning 401 with a
    # WWW-Authenticate challenge is the usual way to make the browser forget
    # cached credentials (cancel the dialog = signed out; submit = sign in again).
    get "/logout" do
      headers["WWW-Authenticate"] = 'Basic realm="MadCP"'
      headers["Cache-Control"] = "no-store"
      content_type :html
      status 401
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head><meta charset="utf-8"><title>MadCP signed out</title></head>
          <body>
            <p>Signed out of the MadCP operator UI.</p>
            <p>Cancel the browser login dialog to stay signed out, or enter your credentials again to continue.</p>
            <p><a href="/servers/">Back to integrations</a></p>
          </body>
        </html>
      HTML
    end

    get ["/servers", "/servers/"] do
      wants_json = request.env["HTTP_ACCEPT"].to_s.include?("application/json")
      if wants_json || params["format"] == "json"
        json(servers: registry.catalog)
      else
        content_type :html
        renderer.page(
          "servers",
          title: "MadCP integrations",
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

    get "/servers/:server_id/auth/status" do
      force = %w[1 true yes].include?(params["refresh"].to_s.downcase)
      status = integration.auth_status(force: force)
      json(
        server_id: integration.id,
        cache_ttl: integration.auth_status_cache_ttl.to_i,
        refreshed: force,
        **status,
      )
    end

    post "/servers/:server_id/auth/credentials" do
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
      state = SecureRandom.urlsafe_base64(32)
      result = integration.oauth_call(callback_url: oauth_callback_url, state: state)
      authorization_url = result[:authorization_url] || result["authorization_url"]
      raise "integration did not return an authorization_url" if authorization_url.to_s.empty?

      # Persist any extra oauth_call fields (e.g. PKCE code_verifier) with the state.
      extra = result.to_h.reject { |key, _| key.to_s == "authorization_url" }
      oauth_retrieval_mutex.synchronize do
        oauth_retrieval_states.delete_if { |_, data| data[:expires_at] < Time.now.to_i }
        oauth_retrieval_states[state] = {
          server_id: integration.id,
          expires_at: Time.now.to_i + 300,
        }.merge(extra.transform_keys(&:to_sym))
      end

      redirect authorization_url, 302
    rescue StandardError => e
      halt 400, json({ error: e.message }, 400)
    end

    get "/servers/:server_id/oauth_callback" do
      headers["Cache-Control"] = "no-store"
      headers["Referrer-Policy"] = "no-referrer"
      require_oauth_token_retrieval!
      callback_params = oauth_query_params
      state = callback_params["state"]
      state_data = consume_oauth_retrieval_state(state)
      halt 400, json({ error: "invalid, expired, or already used OAuth state" }, 400) unless state_data

      result = nil
      token_saved = false
      token_save_error = nil
      if callback_params["code"].is_a?(String) && !callback_params["code"].empty?
        result = integration.oauth_exchange(
          callback_url: oauth_callback_url,
          params: callback_params,
          state_data: state_data,
        )
        if integration.respond_to?(:apply_oauth_result!)
          begin
            integration.apply_oauth_result!(result)
            token_saved = true
          rescue StandardError => e
            token_save_error = e.message
          end
        end
      end
      content_type :html
      renderer.page(
        "oauth_result",
        **integration_locals(
          integration,
          callback_url: oauth_callback_url,
          oauth_params: redact_oauth_secrets(callback_params),
          oauth_result: redact_oauth_secrets(result),
          token_saved: token_saved,
          token_save_error: token_save_error,
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
          token_saved: false,
          token_save_error: nil,
        ),
      )
    end

    post "/servers/:server_id/auth/save_oauth_token" do
      require_oauth_token_retrieval!
      if integration.respond_to?(:apply_oauth_token_paste!)
        integration.apply_oauth_token_paste!(
          access_token: params["access_token"],
          token_json: params["token_json"],
        )
      else
        integration.apply_credentials(
          "#{integration.id}_token" => params["access_token"].to_s,
        )
      end
      redirect "/servers/#{integration.id}/auth", 302
    rescue StandardError => e
      status 400
      content_type :html
      renderer.page(
        "oauth_result",
        **integration_locals(
          integration,
          callback_url: oauth_callback_url,
          oauth_params: {},
          oauth_result: { error: e.message },
          token_saved: false,
          token_save_error: e.message,
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
      integration.apply_credentials(params)
      redirect provider.authorize_login(state: state), 302
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
    rescue StandardError => e
      status 400
      content_type :html
      renderer.page(
        "auth",
        **integration_locals(
          integration,
          state: state,
          error: "#{e.message} — you can still use “Continue to Claude anyway” below.",
          message: nil,
        ),
      )
    end

    # Complete MCP client OAuth without requiring integration credentials to succeed.
    post "/servers/:server_id/auth/continue" do
      state = params["state"].to_s
      halt 400, json({ error: "missing OAuth state" }, 400) if state.empty?

      redirect provider.authorize_login(state: state), 302
    rescue OAuthProvider::OAuthError => e
      oauth_error(e)
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
    end
  end
end
