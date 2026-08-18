# frozen_string_literal: true

module Api
  class BaseController < ApplicationController
    include ApiKeyAuthenticatable

    skip_before_action :verify_authenticity_token
    before_action :authenticate_with_api_key
  end
end
