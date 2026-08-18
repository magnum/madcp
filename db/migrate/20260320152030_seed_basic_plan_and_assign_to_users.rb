# frozen_string_literal: true

class SeedBasicPlanAndAssignToUsers < ActiveRecord::Migration[8.1]
  def up
    basic = PlanType.find_or_create_by!(code: "basic") do |pt|
      pt.name = "Basic"
      pt.description = "Basic plan"
      pt.price = 0
      pt.days = 365
      pt.is_active = true
      pt.is_default = true
    end

    User.find_each do |user|
      next if user.plans.exists?

      Plan.create!(
        plan_type: basic,
        user: user,
        valid_from: Date.current,
        valid_to: Date.current + 365.days
      )
    end
  end

  def down
    PlanType.find_by(code: "basic")&.destroy
  end
end
