# frozen_string_literal: true

class McpServersController < ApplicationController
  before_action :require_authentication

  def index
    McpServer.discover!
    @servers = McpServer.order(:code)
  end

  def show
    @server = McpServer.fetch!(params[:id])
  end
end
