require 'active_support/concern'

module Tokenizable
  extend ActiveSupport::Concern
  include ActionView::Helpers::UrlHelper  
  
  included do
    
      
  end

  class_methods do

  end

  
  def tokenize_text(text, objects=[])
    return nil unless text
    text.scan(/\[.*?\]/).each do |token|
      callable = token.gsub("[", "").gsub("]", "")
      value = eval(callable) rescue ""
      text = text.gsub(token, "#{value}")
    end
    text
  end

end


