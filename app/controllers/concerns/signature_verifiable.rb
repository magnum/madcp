module SignatureVerifiable
  extend ActiveSupport::Concern

  included do
    
  end

  def verify_signature(resource)
    if params[:signature].blank?
      raise "Signature is required"
    end

    if params[:signature] != resource.signature
      raise "Invalid signature"
    end
  end
end