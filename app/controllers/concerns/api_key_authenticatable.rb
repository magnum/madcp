# frozen_string_literal: true

module ApiKeyAuthenticatable
  extend ActiveSupport::Concern

  included do
    attr_reader :current_bearer, :current_api_key
  end

  def authenticate_with_api_key
    if request.params[:token].present?
      return true if api_key?(request.params[:token])

      request_http_token_authentication
      return
    end

    authenticate_or_request_with_http_token do |token, _options|
      api_key?(token)
    end
  end

  def request_http_token_authentication(realm = "EmCP", message = nil)
    json_response = { errors: [message || "Access denied"] }
    headers["WWW-Authenticate"] = %(Bearer realm="#{realm.tr('"', "")}")
    render json: json_response, status: :unauthorized
  end

  def api_key?(token)
    @current_api_key = ApiKey
      .where(revoked_at: nil)
      .where("expires_at is NULL OR expires_at > ?", Time.zone.now)
      .find_by_token(token)
    @current_bearer = current_api_key&.bearer
    current_api_key.present?
  end

  def bearer_token
    pattern = /^Bearer /i
    header = request.authorization.to_s
    return header.sub(pattern, "") if header.match?(pattern)

    params[:token].presence
  end
end
