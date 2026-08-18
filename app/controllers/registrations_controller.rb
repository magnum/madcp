# frozen_string_literal: true

class RegistrationsController < ApplicationController
  include Authentication
  include InvitationProtected

  before_action :redirect_if_signed_in, only: [:new, :create]
  before_action :require_invitation, only: [:new, :create]

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params)
    if @user.save
      session[:user_id] = @user.id
      invitation = current_invitation
      invitation.consume! if invitation&.may_consume?
      redirect_to root_path, notice: t("registrations.created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def user_params
    params.require(:user).permit(:firstname, :lastname, :email, :password, :password_confirmation)
  end
end
