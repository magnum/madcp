# frozen_string_literal: true

class LocaleController < ApplicationController
  def set_session_locale
    session[:locale] = params[:locale] || I18n.default_locale
    redirect_to request.referer || root_path
  end
end
