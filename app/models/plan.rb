# frozen_string_literal: true

class Plan < ApplicationRecord
  belongs_to :plan_type
  belongs_to :user

  validates :valid_from, presence: true
  validates :valid_to, presence: true
  validates :plan_type, presence: true
  validates :user, presence: true
end
