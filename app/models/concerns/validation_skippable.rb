module ValidationSkippable
    extend ActiveSupport::Concern

    included do
        attr_accessor :skip_validation
    end
end