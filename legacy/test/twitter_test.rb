# frozen_string_literal: true

require_relative "test_helper"

require "base64"
require "digest"
require "minitest/autorun"
require_relative "../server"

class TwitterTest < Minitest::Test
  class RecordingClient
    attr_reader :calls, :exchange_args

    def initialize
      @calls = []
      @exchange_args = nil
    end

    def get(path, query: {}, raise_on_error: true)
      @calls << [:get, path, { query: query }]
      if path == "/users/me"
        { status: 200, headers: {}, body: { "data" => { "id" => "42", "username" => "emcp" } } }
      else
        { status: 200, headers: {}, body: { "ok" => true, "path" => path } }
      end
    end

    def post(path, body: nil, query: {}, raise_on_error: true)
      @calls << [:post, path, { body: body, query: query }]
      { status: 200, headers: {}, body: { "ok" => true, "path" => path, "body" => body } }
    end

    def delete(path, query: {}, raise_on_error: true)
      @calls << [:delete, path, { query: query }]
      { status: 200, headers: {}, body: { "ok" => true, "path" => path } }
    end

    def exchange_code(callback_url:, code:, code_verifier:)
      @exchange_args = {
        callback_url: callback_url,
        code: code,
        code_verifier: code_verifier,
      }
      {
        status: 200,
        headers: {},
        body: {
          "access_token" => "access-from-exchange",
          "refresh_token" => "refresh-from-exchange",
          "token_type" => "bearer",
        },
      }
    end
  end

  def setup
    @old_token = ENV["TWITTER_TOKEN"]
    @old_client_id = ENV["TWITTER_CLIENT_ID"]
    @old_client_secret = ENV["TWITTER_CLIENT_SECRET"]
    ENV["TWITTER_TOKEN"] = "test-token"
    ENV["TWITTER_CLIENT_ID"] = "client-id"
    ENV["TWITTER_CLIENT_SECRET"] = "client-secret"
    @integration = Emcp::Servers::Twitter::Server.new(config: CONFIG)
    @client = RecordingClient.new
    @integration.instance_variable_set(:@client, @client)
  end

  def teardown
    restore_env("TWITTER_TOKEN", @old_token)
    restore_env("TWITTER_CLIENT_ID", @old_client_id)
    restore_env("TWITTER_CLIENT_SECRET", @old_client_secret)
  end

  def test_catalog_contains_reads_and_write_gated_mutations
    tools = @integration.tool_catalog

    assert_equal 22, tools.length
    assert tools.any? { |tool| tool[:name] == "twitter_me" && !tool[:write] }
    assert tools.any? { |tool| tool[:name] == "twitter_tweet_create" && tool[:write] }
    assert tools.select { |tool| tool[:write] }.all? { |tool| !tool[:enabled] }
    assert_raises(SecurityError) do
      @integration.call_tool("twitter_tweet_create", text: "hello")
    end
    assert_empty @client.calls
  end

  def test_oauth_call_includes_pkce_challenge_and_verifier
    result = @integration.oauth_call(
      callback_url: "https://emcp.example/servers/twitter/oauth_callback",
      state: "state-1",
    )

    assert result[:code_verifier]
    uri = URI(result[:authorization_url])
    assert_equal "x.com", uri.host
    query = URI.decode_www_form(uri.query).to_h
    assert_equal "S256", query.fetch("code_challenge_method")
    expected = Base64.urlsafe_encode64(Digest::SHA256.digest(result[:code_verifier]), padding: false)
    assert_equal expected, query.fetch("code_challenge")
    assert_equal "state-1", query.fetch("state")
    assert_includes query.fetch("scope"), "tweet.read"
  end

  def test_oauth_exchange_uses_state_data_code_verifier
    result = @integration.oauth_exchange(
      callback_url: "https://emcp.example/servers/twitter/oauth_callback",
      params: { "code" => "auth-code" },
      state_data: { code_verifier: "verifier-xyz" },
    )

    assert_equal 200, result[:status]
    assert_equal "verifier-xyz", @client.exchange_args[:code_verifier]
    assert_equal "auth-code", @client.exchange_args[:code]
  end

  def test_apply_oauth_result_persists_tokens
    path = File.join(@integration.data_dir, "oauth_token.json")
    FileUtils.rm_f(path)

    # Avoid live auth probe: stub auth_status.
    def @integration.auth_status(force: false) = { authenticated: true }

    ok = @integration.apply_oauth_result!(
      status: 200,
      body: {
        "access_token" => "persisted-access",
        "refresh_token" => "persisted-refresh",
      },
    )

    assert ok
    assert_equal "persisted-access", ENV["TWITTER_TOKEN"]
    assert_equal "persisted-refresh", ENV["TWITTER_REFRESH_TOKEN"]
    assert File.file?(path)
    payload = JSON.parse(File.read(path))
    assert_equal "persisted-access", payload["access_token"]
  end

  def test_tweet_create_and_home_timeline
    old = ENV["TWITTER_ALLOW_WRITE"]
    ENV["TWITTER_ALLOW_WRITE"] = "true"
    integration = Emcp::Servers::Twitter::Server.new(config: CONFIG)
    client = RecordingClient.new
    integration.instance_variable_set(:@client, client)

    integration.call_tool("twitter_tweet_create", text: "Hello X")
    method, path, options = client.calls.fetch(0)
    assert_equal :post, method
    assert_equal "/tweets", path
    assert_equal "Hello X", options.dig(:body, "text")

    client.calls.clear
    integration.call_tool("twitter_home_timeline", max_results: 10)
    method, path, options = client.calls.last
    assert_equal :get, method
    assert_equal "/users/42/timelines/reverse_chronological", path
    assert_equal 10, options.dig(:query, :max_results)
  ensure
    restore_env("TWITTER_ALLOW_WRITE", old)
  end

  private

  def restore_env(key, value)
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end
end
