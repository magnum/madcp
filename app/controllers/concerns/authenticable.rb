module Authenticable
    extend ActiveSupport::Concern
  
    included do
      before_action :set_current_user
      helper_method :current_user, :logged_in?
    end
  
      
    private
  
    def authenticate_admin
      unless current_user&.admin?
        redirect_to sign_in_path, alert: t('views.auth.not_authorized')
        return false
      end
    end
  
    def administrate?
      if current_user.blank?
        redirect_to sign_in_path, alert: t('views.auth.not_authorized')
        return false
      end    
    end
  
    def set_current_user
      ::Current.user = current_user
    end
  
    def current_user
      @current_user ||= User.find(session[:user_id]) if session[:user_id]
    rescue ActiveRecord::RecordNotFound
      session[:user_id] = nil
    end
  
    def logged_in?
      !!current_user
    end
  
    def require_login
      unless logged_in?
        flash[:alert] = t('views.auth.login_required')
        redirect_to login_path
      end
    end
  end