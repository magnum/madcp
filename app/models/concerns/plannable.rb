module Plannable
  extend ActiveSupport::Concern

  included do
    has_many :plans
    has_one :current_plan, -> { where("active_from <= ? AND active_to >= ?", Date.today, Date.today).order(active_from: :desc) }, class_name: "Plan"
  end

  def current_plan_type
    self.current_plan.plan_type
  end
  
  
end