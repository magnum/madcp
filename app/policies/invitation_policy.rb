# frozen_string_literal: true

class InvitationPolicy < ApplicationPolicy
  def index?
    admin?
  end

  def show?
    admin?
  end

  def create?
    admin?
  end

  def new?
    admin?
  end

  def update?
    admin?
  end

  def destroy?
    admin?
  end

  def event?
    admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.none
    end
  end
end
