# frozen_string_literal: true

require "test_helper"

class ServerAuthTokenRefreshJobTest < ActiveJob::TestCase
  setup do
    McpServer.discover!
    @server = McpServer.fetch!("twitter")
    @server.update!(service_token_refresh_in_minutes: 90)
  end

  test "does nothing and does not reschedule when service refresh is blank" do
    @server.update!(service_token_refresh_in_minutes: nil)

    assert_no_enqueued_jobs only: ServerAuthTokenRefreshJob do
      ServerAuthTokenRefreshJob.perform_now(@server)
    end
  end

  test "calls refresh_service_token! and reschedules when configured" do
    called = false
    @server.define_singleton_method(:refresh_service_token!) do
      called = true
      true
    end

    assert_enqueued_with(job: ServerAuthTokenRefreshJob, at: 90.minutes.from_now) do
      freeze_time { ServerAuthTokenRefreshJob.perform_now(@server) }
    end
    assert called
  end

  test "reschedules even when refresh returns false" do
    @server.define_singleton_method(:refresh_service_token!) { false }

    assert_enqueued_jobs 1, only: ServerAuthTokenRefreshJob do
      freeze_time { ServerAuthTokenRefreshJob.perform_now(@server) }
    end
  end
end
