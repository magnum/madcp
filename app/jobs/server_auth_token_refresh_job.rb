# frozen_string_literal: true

class ServerAuthTokenRefreshJob < ApplicationJob
  queue_as :default
  discard_on ActiveJob::DeserializationError

  def perform(access_token, expected_expires_at:)
    return if access_token.expires_at.to_i != expected_expires_at.to_i

    access_token.refresh_for_server!
  end
end
