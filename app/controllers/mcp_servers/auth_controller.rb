# frozen_string_literal: true

module McpServers
  class AuthController < ApplicationController
    include McpAuthenticatable

    before_action :require_authentication
    before_action :load_server

    def show
      @state = params[:state]
      if @state.present? && !oauth_provider.valid_state?(@state)
        redirect_to mcp_server_path(@server.code), alert: "Invalid OAuth state"
      end
    end

    def status
      @status = @server.auth_status(force: params[:refresh].present?)

      respond_to do |format|
        format.html do
          render partial: "mcp_servers/auth_status_badge",
                 locals: { server: @server, status: @status }
        end
        format.json do
          render json: @status.merge(
            server_id: @server.code,
            refreshed: params[:refresh].present?,
          )
        end
      end
    end

    def credentials
      @server.apply_credentials(params.to_unsafe_h)
      redirect_to auth_mcp_server_path(@server.code), notice: "Credentials saved"
    rescue StandardError => e
      redirect_to auth_mcp_server_path(@server.code), alert: e.message
    end

    def continue
      state = params[:state].to_s
      redirect_to oauth_provider.authorize_login(state: state), allow_other_host: true
    rescue McpOauthProvider::OAuthError => e
      redirect_to auth_mcp_server_path(@server.code), alert: e.message
    end

    def logout
      count = oauth_provider.revoke_all!
      @server.clear_credentials! if params[:clear_integration].present?
      redirect_to auth_mcp_server_path(@server.code), notice: "Revoked #{count} MCP tokens"
    end

    private

    def load_server
      @server = mcp_server
    end
  end
end
