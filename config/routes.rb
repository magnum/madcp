Rails.application.routes.draw do
  mount MissionControl::Jobs::Engine, at: "/jobs"

  namespace :admin do
    resources :users
    resources :roles
    resources :api_keys
    resources :mcp_servers
    resources :plan_types
    resources :plans
    resources :invitations do
      member do
        put "/event/:event", to: "invitations#event", as: :event
      end
    end
    root to: "users#index"
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "healthz", to: "health#show"

  # MCP host URLs stay unlocalized for connector compatibility.
  resources :mcp_servers, path: "servers", param: :id, only: %i[index show] do
    member do
      post "mcp", to: "mcp_servers/mcp#create"
      get "mcp", to: "mcp_servers/mcp#method_not_allowed"
      delete "mcp", to: "mcp_servers/mcp#method_not_allowed"

      get "tools", to: "mcp_servers/tools#index", as: :tools
      post "tools/:tool", to: "mcp_servers/tools#create"

      get "auth", to: "mcp_servers/auth#show", as: :auth
      get "auth/status", to: "mcp_servers/auth#status", as: :auth_status
      post "auth/credentials", to: "mcp_servers/auth#credentials", as: :auth_credentials
      post "auth/continue", to: "mcp_servers/auth#continue", as: :auth_continue
      match "auth/logout", to: "mcp_servers/auth#logout", via: %i[get post], as: :auth_logout
      post "auth/clear_service", to: "mcp_servers/auth#clear_service", as: :auth_clear_service

      get "auth/authorize", to: "mcp_servers/oauth#authorize"
      post "auth/register", to: "mcp_servers/oauth#register"
      post "auth/token", to: "mcp_servers/oauth#token"
      post "auth/revoke", to: "mcp_servers/oauth#revoke"

      post "oauth", to: "mcp_servers/provider_oauth#create", as: :provider_oauth
      get "oauth_callback", to: "mcp_servers/provider_oauth#callback", as: :oauth_callback
      post "auth/save_oauth_token", to: "mcp_servers/provider_oauth#save_token", as: :save_oauth_token

      get ".well-known/oauth-authorization-server", to: "mcp_servers/oauth#authorization_server"
    end
  end

  get "/.well-known/oauth-protected-resource/servers/:server_id/mcp",
      to: "mcp_servers/oauth#protected_resource"
  get "/.well-known/oauth-authorization-server/servers/:server_id",
      to: "mcp_servers/oauth#authorization_server"
  get "/.well-known/oauth-authorization-server/servers/:server_id/mcp",
      to: "mcp_servers/oauth#authorization_server"

  concern :apiable do
    get "test", to: "test#index"
  end

  scope "/(:locale)", locale: /#{I18n.available_locales.join("|")}/ do
    # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
    # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
    # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

    # Invitation consume: GET /invitations/consume or GET /invitations/consume/:code (pre-filled)
    get "invitations/consume", to: "invitations#consume", as: :invitation_consume
    get "invitations/consume/:code", to: "invitations#consume", as: :invitation_consume_with_code
    post "invitations/consume", to: "invitations#consume"

    # Authentication
    get "sign_in", to: "sessions#new", as: :sign_in
    post "sign_in", to: "sessions#create"
    delete "sign_out", to: "sessions#destroy", as: :sign_out
    get "auth/failure", to: "sessions#failure"
    get "auth/:provider/callback", to: "sessions#create"

    get "sign_up", to: "registrations#new", as: :sign_up
    post "sign_up", to: "registrations#create"

    resources :users, only: [ :index, :show, :edit, :update ]

    namespace :api do
      concerns :apiable
      namespace :v1 do
        concerns :apiable
      end
    end
  end

  get "set_session_locale/:locale", to: "locale#set_session_locale", as: :set_session_locale

  root "mcp_servers#index"
end
