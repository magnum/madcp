# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"
require "uri"

class McpOauthProvider
  ACCESS_TTL = 3600
  REFRESH_TTL = 30 * 24 * 3600
  AUTH_CODE_TTL = 300
  STATE_TTL = 600

  def self.access_ttl_seconds(minutes)
    minutes = minutes.to_i
    return ACCESS_TTL unless minutes.positive?

    (minutes * 60) + ACCESS_TTL
  end

  def self.refresh_ttl_seconds(minutes)
    [ REFRESH_TTL, access_ttl_seconds(minutes) ].max
  end

  class OAuthError < StandardError
    attr_reader :status, :code

    def initialize(status, code, message)
      super(message)
      @status = status
      @code = code
    end

    def payload = { error: @code, error_description: message }
  end

  def initialize(mcp_server)
    @server = mcp_server
  end

  def issuer
    @server.issuer_url
  end

  def scope
    "emcp:#{@server.code}"
  end

  def authorization_server_metadata
    {
      issuer: issuer,
      authorization_endpoint: "#{issuer}/auth/authorize",
      token_endpoint: "#{issuer}/auth/token",
      registration_endpoint: "#{issuer}/auth/register",
      revocation_endpoint: "#{issuer}/auth/revoke",
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
      resource: "#{issuer}/mcp",
      authorization_servers: [issuer],
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
    client = @server.mcp_oauth_clients.create!(
      client_id: SecureRandom.uuid,
      client_secret: auth_method == "none" ? nil : SecureRandom.hex(32),
      client_id_issued_at: Time.now.to_i,
      client_secret_expires_at: 0,
      redirect_uris: redirect_uris,
      token_endpoint_auth_method: auth_method,
      grant_types: Array(metadata["grant_types"] || %w[authorization_code refresh_token]),
      response_types: Array(metadata["response_types"] || ["code"]),
      client_name: metadata["client_name"],
      scope: metadata["scope"] || scope,
    )
    {
      "client_id" => client.client_id,
      "client_secret" => client.client_secret,
      "client_id_issued_at" => client.client_id_issued_at,
      "client_secret_expires_at" => client.client_secret_expires_at,
      "redirect_uris" => client.redirect_uris,
      "token_endpoint_auth_method" => client.token_endpoint_auth_method,
      "grant_types" => client.grant_types,
      "response_types" => client.response_types,
      "client_name" => client.client_name,
      "scope" => client.scope,
    }.compact
  end

  def start_authorization(params)
    client = @server.mcp_oauth_clients.find_by(client_id: params["client_id"].to_s)
    raise OAuthError.new(400, "invalid_request", "unknown client_id") unless client
    raise OAuthError.new(400, "unsupported_response_type", "response_type must be code") unless params["response_type"] == "code"

    redirect_uri = params["redirect_uri"].to_s
    redirect_uri = client.redirect_uris.first if redirect_uri.empty? && client.redirect_uris.one?
    unless client.redirect_uris.include?(redirect_uri)
      raise OAuthError.new(400, "invalid_request", "redirect_uri is missing or not registered")
    end

    challenge = params["code_challenge"].to_s
    raise OAuthError.new(400, "invalid_request", "code_challenge is required") if challenge.empty?
    unless params.fetch("code_challenge_method", "S256") == "S256"
      raise OAuthError.new(400, "invalid_request", "only PKCE S256 is supported")
    end

    login_state = SecureRandom.hex(24)
    @server.mcp_oauth_login_states.create!(
      state: login_state,
      client_id: client.client_id,
      redirect_uri: redirect_uri,
      code_challenge: challenge,
      client_state: params["state"].to_s,
      scope: params["scope"].presence || scope,
      expires_at: STATE_TTL.seconds.from_now,
    )
    "#{issuer}/auth?state=#{URI.encode_www_form_component(login_state)}"
  end

  def valid_state?(state)
    @server.mcp_oauth_login_states.where(state: state).where("expires_at > ?", Time.current).exists?
  end

  def authorize_login(state:)
    state_row = @server.mcp_oauth_login_states.find_by(state: state)
    raise OAuthError.new(400, "invalid_request", "invalid state") unless state_row&.active?

    client = @server.mcp_oauth_clients.find_by!(client_id: state_row.client_id)
    code = "emcp_#{SecureRandom.hex(16)}"
    @server.mcp_oauth_auth_codes.create!(
      mcp_oauth_client: client,
      code: code,
      redirect_uri: state_row.redirect_uri,
      code_challenge: state_row.code_challenge,
      scope: state_row.scope,
      expires_at: AUTH_CODE_TTL.seconds.from_now,
    )
    state_row.destroy!
    values = { code: code }
    values[:state] = state_row.client_state unless state_row.client_state.to_s.empty?
    append_query(state_row.redirect_uri, values)
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

    if ApiKey::HMAC_SECRET_KEY.present?
      api_key = ApiKey.where(revoked_at: nil)
        .where("expires_at is NULL OR expires_at > ?", Time.zone.now)
        .find_by_token(token)
      return { subject: "api_key:#{api_key.id}", expires_at: nil } if api_key
    end

    row = @server.mcp_oauth_access_tokens.active.find_by(token: token)
    return nil unless row

    { subject: "operator", client_id: row.mcp_oauth_client.client_id, expires_at: row.expires_at.to_i }
  end

  def revoke_token(token)
    @server.mcp_oauth_access_tokens.where(token: token).delete_all
    @server.mcp_oauth_refresh_tokens.where(token: token).delete_all
  end

  def revoke_all!
    count = @server.mcp_oauth_access_tokens.count + @server.mcp_oauth_refresh_tokens.count
    @server.mcp_oauth_access_tokens.delete_all
    @server.mcp_oauth_refresh_tokens.delete_all
    @server.mcp_oauth_auth_codes.delete_all
    @server.mcp_oauth_login_states.delete_all
    count
  end

  private

  def exchange_code(params)
    client = authenticate_client(params)
    data = @server.mcp_oauth_auth_codes.find_by(code: params["code"].to_s)
    raise OAuthError.new(400, "invalid_grant", "invalid authorization code") unless data
    raise OAuthError.new(400, "invalid_grant", "authorization code expired") unless data.active?
    raise OAuthError.new(400, "invalid_grant", "client mismatch") unless data.mcp_oauth_client_id == client.id

    verifier = params["code_verifier"].to_s
    expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    raise OAuthError.new(400, "invalid_grant", "PKCE verification failed") unless Emcp.secure_equals(expected, data.code_challenge)

    data.destroy!
    issue_tokens(client, rotate_refresh: false)
  end

  def exchange_refresh(params)
    client = authenticate_client(params)
    data = @server.mcp_oauth_refresh_tokens.find_by(token: params["refresh_token"].to_s)
    raise OAuthError.new(400, "invalid_grant", "invalid refresh token") unless data
    raise OAuthError.new(400, "invalid_grant", "refresh token expired") unless data.active?
    raise OAuthError.new(400, "invalid_grant", "client mismatch") unless data.mcp_oauth_client_id == client.id

    data.destroy!
    issue_tokens(client, rotate_refresh: true)
  end

  def authenticate_client(params)
    client = @server.mcp_oauth_clients.find_by(client_id: params["client_id"].to_s)
    raise OAuthError.new(401, "invalid_client", "unknown client_id") unless client
    if client.token_endpoint_auth_method != "none" &&
       !Emcp.secure_equals(params["client_secret"], client.client_secret)
      raise OAuthError.new(401, "invalid_client", "invalid client_secret")
    end
    client
  end

  def issue_tokens(client, rotate_refresh: false)
    access_ttl = self.class.access_ttl_seconds(@server.token_refresh_in_minutes)
    refresh_ttl = self.class.refresh_ttl_seconds(@server.token_refresh_in_minutes)
    access = upsert_access_token(client, ttl: access_ttl)
    refresh = upsert_refresh_token(client, ttl: refresh_ttl, rotate: rotate_refresh)
    access.schedule_refresh_job!
    {
      access_token: access.token,
      refresh_token: refresh.token,
      token_type: "Bearer",
      expires_in: access_ttl,
      scope: scope,
    }
  end

  def upsert_access_token(client, ttl:)
    relation = @server.mcp_oauth_access_tokens.where(mcp_oauth_client: client)
    record = relation.order(:id).last
    relation.where.not(id: record.id).delete_all if record
    record ||= @server.mcp_oauth_access_tokens.new(mcp_oauth_client: client)
    record.token = "emcp_#{SecureRandom.hex(32)}" if record.token.blank?
    record.scope = scope
    record.expires_at = ttl.seconds.from_now
    record.save!
    record
  end

  def upsert_refresh_token(client, ttl:, rotate:)
    relation = @server.mcp_oauth_refresh_tokens.where(mcp_oauth_client: client)
    if rotate
      relation.delete_all
      record = @server.mcp_oauth_refresh_tokens.new(mcp_oauth_client: client)
    else
      record = relation.order(:id).last
      relation.where.not(id: record.id).delete_all if record
      record ||= @server.mcp_oauth_refresh_tokens.new(mcp_oauth_client: client)
    end
    record.token = "emcp_rt_#{SecureRandom.hex(32)}" if record.token.blank?
    record.scope = scope
    record.expires_at = ttl.seconds.from_now
    record.save!
    record
  end

  def append_query(url, values)
    uri = URI.parse(url)
    query = URI.decode_www_form(uri.query || "")
    values.each { |key, value| query << [key.to_s, value] }
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end
end
