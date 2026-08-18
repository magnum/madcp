# frozen_string_literal: true

class PlanType < ApplicationRecord
  has_many :plans
  has_many :users, through: :plans

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :description, presence: true
  validates :price, presence: true
  validates :days, presence: true
  validates :is_active, inclusion: { in: [true, false] }
  validates :is_default, inclusion: { in: [true, false] }

  scope :active, -> { where(is_active: true) }

  def self.default
    find_by(is_default: true)
  end
end
