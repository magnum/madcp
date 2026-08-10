# frozen_string_literal: true

module McpServers
  class ToolsController < ApplicationController
    include McpAuthenticatable

    skip_before_action :verify_authenticity_token, only: :create
    before_action :authorize_mcp!, only: :create
    before_action :require_authentication, only: :index

    def index
      render json: {
        server_id: mcp_server.code,
        tools: mcp_server.tool_catalog,
      }
    end

    def create
      result = mcp_server.call_tool(params[:tool], tool_params.to_h)
      text = result.respond_to?(:content) ? result.content.first[:text] : result.to_s
      render json: { result: text }
    rescue KeyError, SecurityError, StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def tool_params
      params.except(:controller, :action, :server_id, :tool, :format).permit!
    end
  end
end
