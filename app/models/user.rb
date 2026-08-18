class User < ApplicationRecord
  include ApiKeyable
  include Plannable

  rolify
  has_secure_password validations: false

  validates :email, presence: true, uniqueness: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: false
  validates :firstname, :lastname, presence: true
  validates :password, length: { minimum: 8 }, allow_nil: true
  validate :password_or_oauth
  validate :password_confirmation_match, if: -> { password.present? }

  after_create :create_default_plan

  def self.from_omniauth(auth)
    where(provider: auth.provider, uid: auth.uid).first_or_initialize.tap do |user|
      user.email = auth.info.email
      user.firstname = auth.info.first_name.presence || auth.info.name&.split&.first || "User"
      user.lastname = auth.info.last_name.presence || auth.info.name&.split&.last || "Name"
      user.avatar_url = auth.info.image
      user.provider = auth.provider
      user.uid = auth.uid
      user.save!
    end
  end

  def google_connected?
    provider == "google_oauth2"
  end

  def full_name
    "#{firstname} #{lastname}".strip
  end

  def admin?
    has_role?(:admin)
  end

  def create_default_plan
    plan_type = PlanType.find_by(code: "basic")
    return unless plan_type

    Plan.create!(
      plan_type: plan_type,
      user: self,
      valid_from: Date.current,
      valid_to: Date.current + 365.days
    )
  end

  private

  def password_or_oauth
    return if password_digest.present? || (provider.present? && uid.present?)
    errors.add(:base, "Password can't be blank") if password.blank?
  end

  def password_confirmation_match
    return if password == password_confirmation
    errors.add(:password_confirmation, "doesn't match Password")
  end
end
