# frozen_string_literal: true

class Invitation < ApplicationRecord
  attr_accessor :skip_validation

  CODE_LENGTH = 6

  validates :valid_from, presence: true
  validates :valid_to, presence: true
  validates :code, presence: true, uniqueness: true
  validates :signature, presence: true, uniqueness: true
  validate :valid_to_after_valid_from

  after_initialize :set_default_validity, if: :new_record?
  before_validation :normalize_code_to_lowercase, if: -> { code.present? }
  before_validation :generate_code, on: :create, if: -> { code.blank? }
  before_validation :generate_signature, on: :create, if: -> { signature.blank? }

  scope :valid_now, -> { where("valid_from <= ? AND valid_to >= ?", Time.current, Time.current) }
  scope :by_code, ->(code) { where("LOWER(code) = ?", code.to_s.downcase.strip) }

  include AASM
  aasm column: :state do
    state :created, initial: true
    state :consumed
    state :expired

    event :consume do
      transitions from: :created, to: :consumed, after: :set_consumed_at
    end

    event :expire do
      transitions from: :created, to: :expired
    end

    event :reset do
      transitions from: %i[created consumed expired], to: :created, after: :clear_consumed_at
    end
  end

  def valid_at?(time = Time.current)
    time >= valid_from && time <= valid_to
  end

  def code
    self[:code].to_s.downcase
  end

  def consumable?
    if created?
      if valid_at?
        true
      else
        expire! if may_expire?
        false
      end
    else
      false
    end
  end

  private

  def set_default_validity
    self.valid_from ||= Time.current
    self.valid_to ||= 1.month.from_now
  end

  def normalize_code_to_lowercase
    self[:code] = self[:code].to_s.downcase.strip
  end

  def generate_code
    self[:code] = loop do
      candidate = SecureRandom.alphanumeric(CODE_LENGTH).downcase
      break candidate unless Invitation.exists?(code: candidate)
    end
  end

  def generate_signature
    self.signature = loop do
      candidate = SecureRandom.urlsafe_base64(32)
      break candidate unless Invitation.exists?(signature: candidate)
    end
  end

  def set_consumed_at
    self.consumed_at = Time.current
  end

  def clear_consumed_at
    self.consumed_at = nil
  end

  def valid_to_after_valid_from
    return if valid_from.blank? || valid_to.blank?

    errors.add(:valid_to, :valid_to_after_valid_from) if valid_to < valid_from
  end
end
