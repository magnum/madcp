require "administrate/field/base"

class BadgeField < Administrate::Field::Base
  def to_s
    data
  end
end
