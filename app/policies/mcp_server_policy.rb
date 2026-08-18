# frozen_string_literal: true

class McpServerPolicy < ApplicationPolicy
  def destroy?
    admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.none
    end
  end
end
