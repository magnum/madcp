# frozen_string_literal: true

require "test_helper"

class McpOauthProviderTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ENV["API_KEY_HMAC_SECRET_KEY"] ||= "test-api-key-hmac-secret"
    McpServer.discover!
    @server = McpServer.fetch!("hey")
    @server.update!(token_refresh_in_minutes: nil)
    @provider = McpOauthProvider.new(@server)
  end

  test "registers client and issues tokens via auth code" do
    tokens = complete_auth_code_flow
    assert tokens[:access_token].present?
    assert @provider.load_access_token(tokens[:access_token])
  end

  test "does not enqueue refresh job when token_refresh_in_minutes is blank" do
    assert_no_enqueued_jobs only: MadcpAuthTokenRefreshJob do
      complete_auth_code_flow
    end
  end

  test "enqueues refresh job when token_refresh_in_minutes is set" do
    @server.update!(token_refresh_in_minutes: 45)

    freeze_time do
      tokens = nil
      assert_enqueued_with(job: MadcpAuthTokenRefreshJob, at: 45.minutes.from_now) do
        tokens = complete_auth_code_flow
      end
      assert_equal McpOauthProvider.access_ttl_seconds(45), tokens[:expires_in]
      assert @provider.load_access_token(tokens[:access_token])
    end
  end

  test "keeps the same access token across re-auth and refresh token grant" do
    @server.update!(token_refresh_in_minutes: 45)
    client = register_public_client
    first = complete_auth_code_flow(client: client)
    second = complete_auth_code_flow(client: client)

    assert_equal first[:access_token], second[:access_token]
    assert_equal first[:refresh_token], second[:refresh_token]

    refreshed = @provider.token_request(
      "grant_type" => "refresh_token",
      "refresh_token" => second[:refresh_token],
      "client_id" => client["client_id"],
    )
    assert_equal first[:access_token], refreshed[:access_token]
    refute_equal second[:refresh_token], refreshed[:refresh_token]
    assert @provider.load_access_token(refreshed[:access_token])
  end

  private

  def register_public_client
    @provider.register_client(
      "redirect_uris" => ["http://localhost/callback"],
      "token_endpoint_auth_method" => "none",
    )
  end

  def complete_auth_code_flow(client: register_public_client)
    verifier = "test-verifier-value"
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    auth_url = @provider.start_authorization(
      "client_id" => client["client_id"],
      "response_type" => "code",
      "redirect_uri" => "http://localhost/callback",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "client-state",
    )
    state = URI.decode_www_form(URI(auth_url).query).to_h.fetch("state")
    redirect = @provider.authorize_login(state: state)
    code = URI.decode_www_form(URI(redirect).query).to_h.fetch("code")

    @provider.token_request(
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client["client_id"],
      "code_verifier" => verifier,
      "redirect_uri" => "http://localhost/callback",
    )
  end
end
