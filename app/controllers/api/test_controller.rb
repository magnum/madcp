class Api::TestController < Api::BaseController
  skip_before_action :authenticate_with_api_key

  def index
    render json: { datetime: Time.new }
  end
end
