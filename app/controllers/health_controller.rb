# frozen_string_literal: true

class HealthController < ApplicationController
  def show
    McpServer.discover! if ActiveRecord::Base.connection.data_source_exists?("mcp_servers")
    servers = McpServer.order(:code).map do |server|
      status = server.auth_status
      {
        id: server.code,
        authenticated: status[:authenticated],
        error: status[:error],
      }
    end
    render json: {
      status: "ok",
      version: Emcp::VERSION,
      servers: servers,
    }
  rescue StandardError => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end
end
