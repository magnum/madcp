# frozen_string_literal: true

module McpServers
  class OauthController < ApplicationController
    include McpAuthenticatable

    skip_before_action :verify_authenticity_token
    before_action :set_cors

    def protected_resource
      render json: oauth_provider.protected_resource_metadata
    end

    def authorization_server
      render json: oauth_provider.authorization_server_metadata
    end

    def authorize
      url = oauth_provider.start_authorization(params.to_unsafe_h)
      redirect_to url, allow_other_host: true
    rescue McpOauthProvider::OAuthError => e
      render json: e.payload, status: e.status
    end

    def register
      render json: oauth_provider.register_client(params.to_unsafe_h), status: :created
    rescue McpOauthProvider::OAuthError => e
      render json: e.payload, status: e.status
    end

    def token
      render json: oauth_provider.token_request(params.to_unsafe_h)
    rescue McpOauthProvider::OAuthError => e
      render json: e.payload, status: e.status
    end

    def revoke
      oauth_provider.revoke_token(params[:token].to_s)
      head :ok
    end

    private

    def set_cors
      headers["Access-Control-Allow-Origin"] = "*"
    end
  end
end
