module Cachable
  extend ActiveSupport::Concern


  def uncache!
    self.touch
  end
  
  
end