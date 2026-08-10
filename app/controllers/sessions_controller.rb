# frozen_string_literal: true

class SessionsController < ApplicationController
  include Authentication
  include InvitationProtected

  before_action :redirect_if_signed_in, only: [:new, :create]

  def new
  end

  def create
    if request.env["omniauth.auth"]
      create_from_oauth
    else
      create_from_password
    end
  end

  def destroy
    reset_session
    redirect_to sign_in_path, notice: t("sessions.signed_out")
  end

  def failure
    redirect_to sign_in_path, alert: t("sessions.oauth_failure")
  end

  private

  def create_from_oauth
    auth = request.env["omniauth.auth"]
    existing_user = User.find_by(provider: auth.provider, uid: auth.uid)

    if existing_user.nil?
      invitation = current_invitation
      unless invitation&.consumable?
        redirect_to root_path, alert: t("views.invitations.requires_invitation") and return
      end
    end

    user = User.from_omniauth(auth)
    session[:user_id] = user.id

    invitation = current_invitation
    invitation.consume! if invitation&.may_consume? && existing_user.nil?

    redirect_to root_path, notice: t("sessions.signed_in")
  end

  def create_from_password
    user = User.find_by(email: params[:email]&.downcase)
    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      redirect_to root_path, notice: t("sessions.signed_in")
    else
      flash.now[:alert] = t("sessions.invalid_credentials")
      render :new, status: :unprocessable_entity
    end
  end
end
