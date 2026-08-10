# All Administrate controllers inherit from this
# `Administrate::ApplicationController`, making it the ideal place to put
# authentication logic or other before_actions.
#
# If you want to add pagination or other controller-level concerns,
# you're free to overwrite the RESTful controller actions.
module Admin
  class ApplicationController < Administrate::ApplicationController
    include WithLocale
    helper ApplicationHelper
    helper Heroicon::ApplicationHelper

    include Administrate::Punditize

    include Authenticable
    before_action :administrate?
    rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized


    def event
      path = send("admin_#{requested_resource.class.name.underscore}_path", requested_resource)
      begin
        requested_resource.try(params[:event].to_sym)
        requested_resource.skip_validation = true
        requested_resource.save!
        requested_resource.try("may_#{params[:event]}?".to_sym)
        redirect_to path, notice: t("views.admin.event_success", event: params[:event].humanize)
      rescue => e
        redirect_to path, alert: t("views.admin.event_fail", event: params[:event].humanize, message: e.message)
      end
    end

    private

    def user_not_authorized
      flash[:alert] = t("views.auth.not_authorized")
      redirect_to sign_in_path
    end


    # Override this value to specify the number of elements to display at a time
    # on index pages. Defaults to 20.
    # def records_per_page
    #   params[:per_page] || 20
    # end
  end
end
