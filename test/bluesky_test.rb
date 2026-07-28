# frozen_string_literal: true

require "tmpdir"

ENV["MADCP_PUBLIC_URL"] = "http://localhost:8765"
ENV["MADCP_AUTH_USERNAME"] = "admin"
ENV["MADCP_AUTH_PASSWORD"] = "secret"
ENV["MADCP_AUTH_TOKEN"] = "static-test-token"
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
end
