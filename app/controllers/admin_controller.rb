class AdminController < ApplicationController
    include Authenticable
    before_action :authenticate_admin
end
