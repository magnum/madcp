# frozen_string_literal: true

class InvitationsController < ApplicationController
  def consume
    if request.get?
      @code = params[:code].to_s.strip.downcase
      render :consume
    else
      code = params[:code].to_s.strip
      invitation = Invitation.by_code(code).first

      if invitation&.consumable?
        cookies.permanent[InvitationProtected::INVITATION_COOKIE] = "#{invitation.id},#{invitation.signature}"
        redirect_to sign_up_path, notice: t("views.invitations.invitation_accepted")
      else
        @code = code.downcase
        flash.now[:alert] = t("views.invitations.invitation_invalid")
        render :consume, status: :unprocessable_entity
      end
    end
  end
end
