# frozen_string_literal: true

module McpAuthenticatable
  extend ActiveSupport::Concern
  include ApiKeyAuthenticatable

  def authorize_mcp!
    token = bearer_token
    payload = oauth_provider.load_access_token(token)
    return if payload

    metadata = "#{Madcp.public_url}/.well-known/oauth-protected-resource/servers/#{mcp_server.code}/mcp"
    headers["WWW-Authenticate"] =
      %(Bearer error="invalid_token", resource_metadata="#{metadata}")
    render json: { error: "invalid_token", error_description: "Authentication required" }, status: :unauthorized
  end

  def mcp_server
    @mcp_server ||= McpServer.fetch!(params[:server_id] || params[:id] || params[:code])
  end

  def oauth_provider
    @oauth_provider ||= McpOauthProvider.new(mcp_server)
  end
end
