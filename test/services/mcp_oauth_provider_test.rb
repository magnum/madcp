# frozen_string_literal: true

require "test_helper"

class McpOauthProviderTest < ActiveSupport::TestCase
  setup do
    McpServer.discover!
    @server = McpServer.fetch!("hey")
    @provider = McpOauthProvider.new(@server)
  end

  test "registers client and issues tokens via auth code" do
    verifier = "test-verifier-value"
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    client = @provider.register_client(
      "redirect_uris" => ["http://localhost/callback"],
      "token_endpoint_auth_method" => "none",
    )
    assert client["client_id"].present?

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

    tokens = @provider.token_request(
      "grant_type" => "authorization_code",
      "code" => code,
      "client_id" => client["client_id"],
      "code_verifier" => verifier,
      "redirect_uri" => "http://localhost/callback",
    )
    assert tokens[:access_token].present?
    assert @provider.load_access_token(tokens[:access_token])
  end
end
