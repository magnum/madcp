require 'httparty'

module Webhookable
  extend ActiveSupport::Concern

  included do

  end

  def webhook_url
    raise NotImplementedError, "Subclasses must implement webhook_url"
  end
  
  def webhook! 
    unless webhook_url.present?
      log_warning!("Webhook URL is not set")
      return
    end
    response = HTTParty.post(webhook_url, body: {
      event: "webhook",
      data: self.to_json
    })
    log!(level: (response.code == 200 ? :info : :error), action: "webhook", response_code: response.code, response_body: response.body)
  end

end