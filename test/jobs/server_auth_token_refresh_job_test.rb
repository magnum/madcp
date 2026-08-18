# frozen_string_literal: true

require "test_helper"

class ServerAuthTokenRefreshJobTest < ActiveJob::TestCase
  setup do
    McpServer.discover!
    @server = McpServer.fetch!("hey")
    @server.update!(token_refresh_in_minutes: 45)
    @client = @server.mcp_oauth_clients.create!(
      client_id: SecureRandom.uuid,
      client_id_issued_at: Time.now.to_i,
      token_endpoint_auth_method: "none",
    )
    @access = @server.mcp_oauth_access_tokens.create!(
      mcp_oauth_client: @client,
      token: "madcp_#{SecureRandom.hex(8)}",
      expires_at: 1.hour.from_now,
    )
    @refresh = @server.mcp_oauth_refresh_tokens.create!(
      mcp_oauth_client: @client,
      token: "madcp_rt_#{SecureRandom.hex(8)}",
      expires_at: 2.days.from_now,
    )
  end

  test "extends token expiry and reschedules when configured" do
    freeze_time do
      original_access = @access.expires_at
      original_refresh = @refresh.expires_at
      token_value = @access.token
      expected = @access.expires_at.to_i

      assert_enqueued_with(job: ServerAuthTokenRefreshJob, at: 45.minutes.from_now) do
        ServerAuthTokenRefreshJob.perform_now(@access, expected_expires_at: expected)
      end

      @access.reload
      @refresh.reload
      assert_equal token_value, @access.token
      assert @access.expires_at > original_access
      assert @refresh.expires_at > original_refresh
      assert_equal McpOauthProvider.access_ttl_seconds(45).seconds.from_now.to_i, @access.expires_at.to_i
    end
  end

  test "ignores stale jobs after a newer authentication" do
    stale = @access.expires_at.to_i
    @access.update!(expires_at: 3.hours.from_now)

    assert_no_enqueued_jobs only: ServerAuthTokenRefreshJob do
      ServerAuthTokenRefreshJob.perform_now(@access, expected_expires_at: stale)
    end

    assert_equal 3.hours.from_now.to_i, @access.reload.expires_at.to_i
  end

  test "does nothing when token_refresh_in_minutes is blank" do
    @server.update!(token_refresh_in_minutes: nil)
    original = @access.expires_at

    assert_no_enqueued_jobs only: ServerAuthTokenRefreshJob do
      ServerAuthTokenRefreshJob.perform_now(@access, expected_expires_at: @access.expires_at.to_i)
    end

    assert_equal original.to_i, @access.reload.expires_at.to_i
  end
end
