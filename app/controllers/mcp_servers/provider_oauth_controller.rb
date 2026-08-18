# frozen_string_literal: true

module McpServers
  class ProviderOauthController < ApplicationController
    include McpAuthenticatable

    before_action :require_authentication, only: :create
    skip_before_action :verify_authenticity_token, only: [:callback, :save_token]

    def create
      return unless oauth_token_retrieval_enabled?

      state = SecureRandom.hex(24)
      result = mcp_server.oauth_call(
        callback_url: "#{Madcp.public_url}/servers/#{mcp_server.code}/oauth_callback",
        state: state,
      )
      mcp_server.mcp_provider_oauth_states.create!(
        state: state,
        payload: result.except(:authorization_url),
        expires_at: 10.minutes.from_now,
      )
      redirect_to result.fetch(:authorization_url), allow_other_host: true
    rescue StandardError => e
      redirect_to auth_mcp_server_path(mcp_server.code), alert: e.message
    end

    def callback
      state = params[:state].to_s
      row = mcp_server.mcp_provider_oauth_states.find_by(state: state)
      unless row&.active?
        return render plain: "invalid or expired OAuth state", status: :bad_request
      end

      state_data = row.payload
      row.destroy!
      result = mcp_server.oauth_exchange(
        callback_url: "#{Madcp.public_url}/servers/#{mcp_server.code}/oauth_callback",
        params: params.to_unsafe_h,
        state_data: state_data,
      )
      mcp_server.apply_oauth_result!(result)
      redirect_to auth_mcp_server_path(mcp_server.code), notice: "Provider OAuth completed"
    rescue StandardError => e
      @error = e.message
      @server = mcp_server
      render :callback_error, status: :unprocessable_entity
    end

    def save_token
      require_authentication
      return unless oauth_token_retrieval_enabled?

      mcp_server.apply_oauth_token_paste!(
        access_token: params[:access_token],
        token_json: params[:token_json],
      )
      redirect_to auth_mcp_server_path(mcp_server.code), notice: "Token saved"
    rescue StandardError => e
      redirect_to auth_mcp_server_path(mcp_server.code), alert: e.message
    end

    private

    def oauth_token_retrieval_enabled?
      return true if mcp_server.oauth_token_retrieval?

      redirect_to auth_mcp_server_path(mcp_server.code),
                  alert: "OAuth token retrieval is not available for this integration"
      false
    end
  end
end
