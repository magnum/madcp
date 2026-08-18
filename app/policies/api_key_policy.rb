class ApiKeyPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    user.admin? || record.bearer == user
  end

  def create?
    user.admin? || record.bearer == user
  end

  def new?
    create?
  end

  def update?
    user.admin? || record.bearer == user
  end

  def destroy?
    user.admin? || record.bearer == user
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user.admin? ? scope.all : scope.where(bearer: user)
    end
  end
end
