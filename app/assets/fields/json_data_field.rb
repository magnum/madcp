require "administrate/field/base"

class JsonDataField < Administrate::Field::Base
  def to_s
    data
  end
end
