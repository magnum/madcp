# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  included do
    helper_method :current_user, :signed_in?
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id]) if session[:user_id]
  end

  def signed_in?
    current_user.present?
  end

  def require_authentication
    return if signed_in?
    redirect_to sign_in_path, alert: t("authentication.require_sign_in")
  end

  def redirect_if_signed_in
    redirect_to root_path, notice: t("authentication.already_signed_in") if signed_in?
  end
end
