class ApplicationController < ActionController::Base
  include Authentication
  include WithLocale
  include Pundit::Authorization

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Authentication helpers
  helper_method :current_user, :logged_in?

  before_action :set_active_storage_url_options

  def default_url_options
    { locale: I18n.locale }
  end

  private

  def set_active_storage_url_options
    ActiveStorage::Current.url_options = { host: request.base_url }
  end

  def current_user
    @current_user ||= User.find(session[:user_id]) if session[:user_id]
  rescue ActiveRecord::RecordNotFound
    session[:user_id] = nil
    nil
  end

  def logged_in?
    !!current_user
  end

  def require_login
    unless logged_in?
      flash[:alert] = t("views.auth.login_required")
      redirect_to sign_in_path
    end
  end
end
