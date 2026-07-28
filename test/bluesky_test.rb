# frozen_string_literal: true

require "tmpdir"
require "openssl"

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
ENV["MADCP_SECRET_KEY"] = "test-secret-key"
ENV["MADCP_AUTH_USERS_PATH"] = File.join(Dir.tmpdir, "madcp-auth-users-#{Process.pid}")
File.write(ENV["MADCP_AUTH_USERS_PATH"], "user1:" + OpenSSL::HMAC.hexdigest("SHA256", "test-secret-key", "secret") + " # test\n")
ENV["MADCP_ALLOWED_HOSTS"] = "localhost,127.0.0.1"
ENV["MADCP_ALLOW_WRITE"] = "false"
ENV["MADCP_REQUEST_LOG"] ||= File.join(Dir.tmpdir, "madcp-test-requests-#{Process.pid}.logs")

require "minitest/autorun"
require_relative "../server"

class BlueskyTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def ensure_session!
      { did: "did:plc:test", handle: "test.bsky.social" }
    end

    def get(nsid, query: {}, auth: true, raise_on_error: true)
      @calls << [:get, nsid, { query: query, auth: auth }]
      { status: 200, headers: {}, body: { "ok" => true, "nsid" => nsid, "query" => query } }
    end

    def post(nsid, body: {}, query: {}, auth: true, raise_on_error: true)
      @calls << [:post, nsid, { body: body, query: query, auth: auth }]
      { status: 200, headers: {}, body: { "ok" => true, "nsid" => nsid, "body" => body } }
    end

    def did = "did:plc:test"
    def handle = "test.bsky.social"
  end

  def setup
    @old_did = ENV["BLUESKY_DID"]
    @old_handle = ENV["BLUESKY_HANDLE"]
    ENV["BLUESKY_DID"] = "did:plc:test"
    ENV["BLUESKY_HANDLE"] = "test.bsky.social"
    @integration = Madcp::Servers::Bluesky::Server.new(config: CONFIG)
    @client = RecordingClient.new
    @integration.instance_variable_set(:@client, @client)
  end

  def teardown
    if @old_did
      ENV["BLUESKY_DID"] = @old_did
    else
      ENV.delete("BLUESKY_DID")
    end
    if @old_handle
      ENV["BLUESKY_HANDLE"] = @old_handle
    else
      ENV.delete("BLUESKY_HANDLE")
    end
  end

  def test_catalog_contains_reads_and_write_gated_mutations
    tools = @integration.tool_catalog

    assert_equal 22, tools.length
    assert tools.any? { |tool| tool[:name] == "bluesky_get_timeline" && !tool[:write] }
    assert tools.any? { |tool| tool[:name] == "bluesky_create_post" && tool[:write] }
    assert tools.select { |tool| tool[:write] }.all? { |tool| !tool[:enabled] }
    assert_raises(SecurityError) do
      @integration.call_tool("bluesky_create_post", text: "hello")
    end
    assert_empty @client.calls
  end

  def test_get_profile_passes_actor
    @integration.call_tool("bluesky_get_profile", actor: "alice.bsky.social")

    method, nsid, options = @client.calls.fetch(0)
    assert_equal :get, method
    assert_equal "app.bsky.actor.getProfile", nsid
    assert_equal "alice.bsky.social", options.dig(:query, :actor)
  end

  def test_create_post_builds_record
    old = ENV["BLUESKY_ALLOW_WRITE"]
    ENV["BLUESKY_ALLOW_WRITE"] = "true"
    integration = Madcp::Servers::Bluesky::Server.new(config: CONFIG)
    client = RecordingClient.new
    integration.instance_variable_set(:@client, client)

    integration.call_tool("bluesky_create_post", text: "Hello Bluesky")

    method, nsid, options = client.calls.fetch(0)
    assert_equal :post, method
    assert_equal "com.atproto.repo.createRecord", nsid
    assert_equal "did:plc:test", options.dig(:body, :repo)
    assert_equal "app.bsky.feed.post", options.dig(:body, :collection)
    assert_equal "Hello Bluesky", options.dig(:body, :record, "text")
    assert_equal "app.bsky.feed.post", options.dig(:body, :record, "$type")
  ensure
    if old
      ENV["BLUESKY_ALLOW_WRITE"] = old
    else
      ENV.delete("BLUESKY_ALLOW_WRITE")
    end
  end

  def test_delete_post_extracts_rkey_from_uri
    old = ENV["BLUESKY_ALLOW_WRITE"]
    ENV["BLUESKY_ALLOW_WRITE"] = "true"
    integration = Madcp::Servers::Bluesky::Server.new(config: CONFIG)
    client = RecordingClient.new
    integration.instance_variable_set(:@client, client)

    integration.call_tool(
      "bluesky_delete_post",
      uri: "at://did:plc:test/app.bsky.feed.post/3k2y",
    )

    _method, _nsid, options = client.calls.fetch(0)
    assert_equal "3k2y", options.dig(:body, :rkey)
    assert_equal "app.bsky.feed.post", options.dig(:body, :collection)
  ensure
    if old
      ENV["BLUESKY_ALLOW_WRITE"] = old
    else
      ENV.delete("BLUESKY_ALLOW_WRITE")
    end
  end

  def test_create_session_keeps_jwts_unredacted_for_apply_session
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) do
      JSON.generate(
        "did" => "did:plc:abc",
        "handle" => "alice.bsky.social",
        "accessJwt" => "access.jwt.token",
        "refreshJwt" => "refresh.jwt.token",
      )
    end
    response.define_singleton_method(:each_header) do |&block|
      next enum_for(:each_header) unless block

      block.call("content-type", "application/json")
    end
    fake_http = Object.new
    fake_http.define_singleton_method(:request) { |_request| response }

    old_handle = ENV["BLUESKY_HANDLE"]
    old_password = ENV["BLUESKY_APP_PASSWORD"]
    old_access = ENV["BLUESKY_ACCESS_JWT"]
    old_refresh = ENV["BLUESKY_REFRESH_JWT"]
    old_did = ENV["BLUESKY_DID"]
    ENV["BLUESKY_HANDLE"] = "alice.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "xxxx-xxxx-xxxx-xxxx"
    ENV.delete("BLUESKY_ACCESS_JWT")
    ENV.delete("BLUESKY_REFRESH_JWT")
    ENV.delete("BLUESKY_DID")

    persisted = nil
    client = Madcp::Servers::Bluesky::Client.new(
      on_session: lambda { |**kwargs| persisted = kwargs },
    )
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &block| block.call(fake_http) }

    client.create_session!

    assert_equal "access.jwt.token", ENV["BLUESKY_ACCESS_JWT"]
    assert_equal "refresh.jwt.token", ENV["BLUESKY_REFRESH_JWT"]
    assert_equal "did:plc:abc", ENV["BLUESKY_DID"]
    assert_equal "access.jwt.token", persisted[:access_jwt]
    refute_equal "[REDACTED]", ENV["BLUESKY_ACCESS_JWT"]
  ensure
    Net::HTTP.define_singleton_method(:start) do |*args, **kwargs, &block|
      original_start.call(*args, **kwargs, &block)
    end if original_start
    restore = lambda do |key, value|
      if value
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
    restore.call("BLUESKY_HANDLE", old_handle)
    restore.call("BLUESKY_APP_PASSWORD", old_password)
    restore.call("BLUESKY_ACCESS_JWT", old_access)
    restore.call("BLUESKY_REFRESH_JWT", old_refresh)
    restore.call("BLUESKY_DID", old_did)
  end
end
