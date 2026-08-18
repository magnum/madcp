# frozen_string_literal: true

class RolePolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.none
    end
  end
end
