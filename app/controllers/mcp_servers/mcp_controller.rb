# frozen_string_literal: true

module McpServers
  class McpController < ApplicationController
    include McpAuthenticatable

    skip_before_action :verify_authenticity_token
    before_action :authorize_mcp!

    def create
      body = request.body.read
      if body.blank?
        return render json: { error: "empty request body" }, status: :bad_request
      end

      result = mcp_server.handle_mcp_json(body)
      if result.nil?
        head :accepted
      elsif result.is_a?(String)
        render plain: result, content_type: "application/json"
      else
        render json: result
      end
    end

    def method_not_allowed
      response.set_header("Allow", "POST")
      head :method_not_allowed
    end
  end
end
