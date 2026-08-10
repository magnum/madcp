# frozen_string_literal: true

module InvitationProtected
  extend ActiveSupport::Concern

  INVITATION_COOKIE = "madcp_invitation"

  included do
    # no-op: allow including controller to call require_invitation as before_action
  end

  # Returns the invitation from the cookie if present and signature valid (for use after signup to consume it).
  def current_invitation
    current_invitation_from_cookie
  end

  private

  def require_invitation
    invitation = current_invitation_from_cookie
    return if invitation&.consumable?

    flash[:alert] = t("views.invitations.requires_invitation")
    redirect_to root_path
  end

  def current_invitation_from_cookie
    raw = cookies[INVITATION_COOKIE]
    return nil if raw.blank?

    id, signature = raw.to_s.split(",", 2).map(&:strip)
    return nil if id.blank? || signature.blank?

    invitation = Invitation.find_by(id: id)
    return nil unless invitation
    return nil unless ActiveSupport::SecurityUtils.secure_compare(invitation.signature, signature)

    invitation
  end
end
