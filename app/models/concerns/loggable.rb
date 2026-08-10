module Loggable
    extend ActiveSupport::Concern

    included do
        has_many :logs, ->{order(created_at: :desc)}, as: :loggable, dependent: :destroy
    end

    def log_info!(message=nil)
        self.log!(:info, message)
    end
    def log_warning!(message=nil)
        self.log!(:warning, message)
    end
    def log_error!(message=nil)
        self.log!(:error, message)
    end


    def log!(level, message=nil)
        if message.blank?
            message = level
            level = :info
        end
        level ||= :info
        message = message.map{|k,v| "#{k}: #{v}"}.join(", ") if message.is_a?(Hash)
        self.logs.create!(
            level: level,
            message: message,
        )
    end

    def logs_clear!
        self.logs.destroy_all
    end
end