# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "uri"

module Madcp
  class OAuthProvider
    ACCESS_TTL = 3600
    REFRESH_TTL = 30 * 24 * 3600
    AUTH_CODE_TTL = 300

    class OAuthError < StandardError
      attr_reader :status, :code

      def initialize(status, code, message)
        super(message)
        @status = status
        @code = code
      end

      def payload = { error: @code, error_description: message }
    end

    attr_reader :issuer

    def initialize(config:, integration:)
      @config = config
      @integration = integration
      @issuer = "#{config.public_url}/servers/#{integration.id}"
      @clients = {}
      @states = {}
      @auth_codes = {}
      @access_tokens = {}
      @refresh_tokens = {}
      @mutex = Mutex.new
      load_store!
    end

    def authorization_server_metadata
      {
        issuer: @issuer,
        authorization_endpoint: "#{@issuer}/auth/authorize",
        token_endpoint: "#{@issuer}/auth/token",
        registration_endpoint: "#{@issuer}/auth/register",
        revocation_endpoint: "#{@issuer}/auth/revoke",
        scopes_supported: [scope],
        response_types_supported: ["code"],
        grant_types_supported: %w[authorization_code refresh_token],
        token_endpoint_auth_methods_supported: %w[client_secret_post none],
        revocation_endpoint_auth_methods_supported: %w[client_secret_post none],
        code_challenge_methods_supported: ["S256"],
      }
    end

    def protected_resource_metadata
      {
        resource: "#{@issuer}/mcp",
        authorization_servers: [@issuer],
        scopes_supported: [scope],
        bearer_methods_supported: ["header"],
      }
    end

    def register_client(metadata)
      redirect_uris = Array(metadata["redirect_uris"]).map(&:to_s).reject(&:empty?)
      raise OAuthError.new(400, "invalid_client_metadata", "redirect_uris is required") if redirect_uris.empty?

      redirect_uris.each do |redirect_uri|
        uri = URI.parse(redirect_uri)
        raise URI::InvalidURIError unless uri.scheme && uri.host
      rescue URI::InvalidURIError
        raise OAuthError.new(400, "invalid_redirect_uri", "invalid redirect_uri: #{redirect_uri}")
      end

      auth_method = metadata.fetch("token_endpoint_auth_method", "client_secret_post")
      client_id = SecureRandom.uuid
      client = {
        "client_id" => client_id,
        "client_secret" => auth_method == "none" ? nil : SecureRandom.hex(32),
        "client_id_issued_at" => Time.now.to_i,
        "client_secret_expires_at" => 0,
        "redirect_uris" => redirect_uris,
        "token_endpoint_auth_method" => auth_method,
        "grant_types" => Array(metadata["grant_types"] || %w[authorization_code refresh_token]),
        "response_types" => Array(metadata["response_types"] || ["code"]),
        "client_name" => metadata["client_name"],
        "scope" => metadata["scope"] || scope,
      }.compact
      @mutex.synchronize do
        @clients[client_id] = client
        persist_store!
      end
      client
    end

    def start_authorization(params)
      client = @mutex.synchronize { @clients[params["client_id"].to_s] }
      raise OAuthError.new(400, "invalid_request", "unknown client_id") unless client
      raise OAuthError.new(400, "unsupported_response_type", "response_type must be code") unless params["response_type"] == "code"

      redirect_uri = params["redirect_uri"].to_s
      redirect_uri = client["redirect_uris"].first if redirect_uri.empty? && client["redirect_uris"].one?
      unless client["redirect_uris"].include?(redirect_uri)
        raise OAuthError.new(400, "invalid_request", "redirect_uri is missing or not registered")
      end

      challenge = params["code_challenge"].to_s
      raise OAuthError.new(400, "invalid_request", "code_challenge is required") if challenge.empty?
      unless params.fetch("code_challenge_method", "S256") == "S256"
        raise OAuthError.new(400, "invalid_request", "only PKCE S256 is supported")
      end

      client_state = params["state"].to_s
      login_state = SecureRandom.hex(24)
      @mutex.synchronize do
        @states[login_state] = {
          client_id: client["client_id"],
          redirect_uri: redirect_uri,
          code_challenge: challenge,
          resource: params["resource"],
          client_state: client_state,
        }
      end
      "#{@issuer}/auth?state=#{URI.encode_www_form_component(login_state)}"
    end

    def valid_state?(state)
      @mutex.synchronize { @states.key?(state) }
    end

    # Completes the MCP client authorization code flow. Caller must already have
    # authenticated the operator (HTTP Basic Auth on the UI).
    def authorize_login(state:)
      state_data = @mutex.synchronize { @states.delete(state) }
      raise OAuthError.new(400, "invalid_request", "invalid state") unless state_data

      code = "madcp_#{SecureRandom.hex(16)}"
      @mutex.synchronize do
        @auth_codes[code] = state_data.merge(
          code: code,
          expires_at: Time.now.to_i + AUTH_CODE_TTL,
          subject: "operator",
        )
      end
      values = { code: code }
      values[:state] = state_data[:client_state] unless state_data[:client_state].empty?
      append_query(state_data[:redirect_uri], values)
    end

    def token_request(params)
      case params["grant_type"]
      when "authorization_code" then exchange_code(params)
      when "refresh_token" then exchange_refresh(params)
      else
        raise OAuthError.new(400, "unsupported_grant_type", "unsupported grant_type")
      end
    end

    def load_access_token(token)
      return nil if token.to_s.empty?

      entry = @config.auth_token_store.lookup(token)
      return { subject: entry.label, expires_at: nil } if entry

      @mutex.synchronize do
        data = @access_tokens[token]
        return nil unless data
        if data[:expires_at] < Time.now.to_i
          @access_tokens.delete(token)
          persist_store!
          return nil
        end
        data
      end
    end

    def revoke_token(token)
      @mutex.synchronize do
        @access_tokens.delete(token)
        @refresh_tokens.delete(token)
        persist_store!
      end
    end

    def revoke_all!
      @mutex.synchronize do
        count = @access_tokens.size + @refresh_tokens.size
        @access_tokens.clear
        @refresh_tokens.clear
        @auth_codes.clear
        @states.clear
        persist_store!
        count
      end
    end

    private

    def scope = "madcp:#{@integration.id}"

    def store_path
      File.join(@config.root, "data", "_oauth", "#{@integration.id}.json")
    end

    def load_store!
      return unless File.file?(store_path)

      data = JSON.parse(File.read(store_path))
      @clients = data.fetch("clients", {})
      @access_tokens = deserialize_token_map(data["access_tokens"])
      @refresh_tokens = deserialize_token_map(data["refresh_tokens"])
    rescue JSON::ParserError, Errno::ENOENT
      @clients = {}
      @access_tokens = {}
      @refresh_tokens = {}
    end

    def persist_store!
      FileUtils.mkdir_p(File.dirname(store_path))
      payload = {
        "clients" => @clients,
        "access_tokens" => serialize_token_map(@access_tokens),
        "refresh_tokens" => serialize_token_map(@refresh_tokens),
      }
      tmp = "#{store_path}.#{Process.pid}.tmp"
      File.write(tmp, JSON.generate(payload), perm: 0o600)
      File.rename(tmp, store_path)
    end

    def serialize_token_map(map)
      map.transform_values do |data|
        data.transform_keys(&:to_s)
      end
    end

    def deserialize_token_map(raw)
      (raw || {}).transform_values do |data|
        data.transform_keys(&:to_sym)
      end
    end

    def exchange_code(params)
      client = authenticate_client(params)
      data = @mutex.synchronize { @auth_codes[params["code"].to_s] }
      raise OAuthError.new(400, "invalid_grant", "invalid authorization code") unless data
      raise OAuthError.new(400, "invalid_grant", "authorization code expired") if data[:expires_at] < Time.now.to_i
      raise OAuthError.new(400, "invalid_grant", "client mismatch") unless data[:client_id] == client["client_id"]

      verifier = params["code_verifier"].to_s
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      raise OAuthError.new(400, "invalid_grant", "PKCE verification failed") unless secure_equals(expected, data[:code_challenge])

      @mutex.synchronize { @auth_codes.delete(data[:code]) }
      issue_tokens(client["client_id"], data[:subject], data[:resource])
    end

    def exchange_refresh(params)
      client = authenticate_client(params)
      data = @mutex.synchronize do
        deleted = @refresh_tokens.delete(params["refresh_token"].to_s)
        if deleted
          # Persist rotation immediately so a crash cannot leave the old
          # refresh token valid alongside a newly issued one.
          persist_store!
        end
        deleted
      end
      raise OAuthError.new(400, "invalid_grant", "invalid refresh token") unless data
      raise OAuthError.new(400, "invalid_grant", "refresh token expired") if data[:expires_at] < Time.now.to_i
      raise OAuthError.new(400, "invalid_grant", "client mismatch") unless data[:client_id] == client["client_id"]

      issue_tokens(client["client_id"], data[:subject], data[:resource])
    end

    def authenticate_client(params)
      client = @mutex.synchronize { @clients[params["client_id"].to_s] }
      raise OAuthError.new(401, "invalid_client", "unknown client_id") unless client
      if client["token_endpoint_auth_method"] != "none" &&
         !secure_equals(params["client_secret"], client["client_secret"])
        raise OAuthError.new(401, "invalid_client", "invalid client_secret")
      end
      client
    end

    def issue_tokens(client_id, subject, resource)
      access = "madcp_#{SecureRandom.hex(32)}"
      refresh = "madcp_rt_#{SecureRandom.hex(32)}"
      now = Time.now.to_i
      @mutex.synchronize do
        @access_tokens[access] = {
          client_id: client_id, subject: subject, resource: resource,
          expires_at: now + ACCESS_TTL,
        }
        @refresh_tokens[refresh] = {
          token: refresh, client_id: client_id, subject: subject, resource: resource,
          expires_at: now + REFRESH_TTL,
        }
        persist_store!
      end
      {
        access_token: access,
        refresh_token: refresh,
        token_type: "Bearer",
        expires_in: ACCESS_TTL,
        scope: scope,
      }
    end

    def secure_equals(a, b)
      OpenSSL.fixed_length_secure_compare(
        Digest::SHA256.digest(a.to_s),
        Digest::SHA256.digest(b.to_s),
      )
    end

    def append_query(url, values)
      uri = URI.parse(url)
      query = URI.decode_www_form(uri.query || "")
      values.each { |key, value| query << [key.to_s, value] }
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end
  end
end
