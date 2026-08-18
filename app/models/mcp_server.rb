# frozen_string_literal: true

require "fileutils"
require "json"
require "mcp"

class McpServer < ApplicationRecord
  include McpServer::Tools
  include McpServer::Credentials
  include McpServer::AuthStatus

  has_many :mcp_oauth_clients, dependent: :destroy
  has_many :mcp_oauth_access_tokens, dependent: :destroy
  has_many :mcp_oauth_refresh_tokens, dependent: :destroy
  has_many :mcp_oauth_auth_codes, dependent: :destroy
  has_many :mcp_oauth_login_states, dependent: :destroy
  has_many :mcp_provider_oauth_states, dependent: :destroy

  encrypts :credentials, :oauth_token_payload

  validates :code, presence: true, uniqueness: true
  validates :name, presence: true
  validates :type, presence: true
  validates :token_refresh_in_minutes,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true

  before_validation :normalize_token_refresh_in_minutes

  after_initialize :prepare_runtime
  after_find :prepare_runtime

  def credentials_hash
    parse_json_attr(credentials)
  end

  def credentials_hash=(value)
    self.credentials = JSON.generate(value || {})
  end

  def oauth_token_hash
    parse_json_attr(oauth_token_payload)
  end

  def oauth_token_hash=(value)
    self.oauth_token_payload = value.nil? ? nil : JSON.generate(value)
  end

  class << self
    attr_reader :server_id_value, :display_name_value, :description_value, :version_value

    def server_id(value = nil)
      @server_id_value = value if value
      @server_id_value
    end

    def display_name(value = nil)
      @display_name_value = value if value
      @display_name_value || server_id
    end

    def description(value = nil)
      @description_value = value if value
      @description_value || ""
    end

    def version(value = nil)
      @version_value = value if value
      @version_value || "1.0.0"
    end

    def oauth_token_retrieval(value = nil)
      @oauth_token_retrieval_value = !!value unless value.nil?
      @oauth_token_retrieval_value || false
    end

    def integration_classes
      @integration_classes ||= []
    end

    def register_integration(klass)
      integration_classes << klass unless integration_classes.include?(klass)
    end

    # servers/ is outside Zeitwerk. After a reload, McpServer is a new class while
    # previously required Madcp::Servers::* still subclass the old one — break STI.
    def discover!
      ensure_integrations_loaded!
      sync_from_registry!
    end

    def ensure_integrations_loaded!
      if Rails.application.config.cache_classes
        load_integration_code! if integration_classes.empty?
      else
        reload_integration_code!
      end
    end

    def load_integration_code!
      Rails.root.glob("servers/*/server.rb").sort.each { |path| require path.to_s }
    end

    def reload_integration_code!
      @integration_classes = []
      unload_servers_namespace!
      clear_servers_loaded_features!
      load_integration_code!
    end

    def unload_servers_namespace!
      return unless Madcp.const_defined?(:Servers, false)

      Madcp.send(:remove_const, :Servers)
    end

    def clear_servers_loaded_features!
      root = Rails.root.join("servers").to_s
      $LOADED_FEATURES.reject! { |feature| feature.start_with?(root) }
    end
    private :unload_servers_namespace!, :clear_servers_loaded_features!

    def sync_from_registry!
      now = Time.current
      integration_classes.each do |klass|
        code = klass.server_id
        next if code.blank?

        allow_write = ActiveModel::Type::Boolean.new.cast(
          ENV.fetch("#{code.upcase}_ALLOW_WRITE", "false"),
        )
        attrs = {
          name: klass.display_name,
          description: klass.description,
          version: klass.version,
          oauth_token_retrieval: klass.oauth_token_retrieval,
          allow_write: allow_write,
          updated_at: now,
        }
        existing = McpServer.find_by(code: code)
        if existing
          existing.update_columns(attrs)
        else
          McpServer.insert({
            code: code,
            type: klass.name,
            created_at: now,
            **attrs,
          })
        end
      end
    end

    def fetch!(code)
      find_by!(code: code.to_s)
    end
  end

  # Legacy Integration used #id for server_id; AR #id remains the PK.
  def server_id = code
  def display_name = name
  def oauth_token_retrieval? = oauth_token_retrieval
  def allow_write_methods? = allow_write?
  def token_refresh_enabled? = token_refresh_in_minutes.to_i.positive?

  def instructions = "#{display_name} MCP integration."
  def auth_fields = []
  def auth_help_content = nil
  def configure_tools = raise(NotImplementedError)
  def apply_credentials(_params) = raise(NotImplementedError)
  def clear_credentials! = raise(NotImplementedError)
  def oauth_call(callback_url:, state:) = raise(NotImplementedError)
  def oauth_exchange(callback_url:, params:, state_data: nil) = raise(NotImplementedError)

  def apply_oauth_result!(result)
    store_oauth_token_payload!(
      oauth_result_body(result),
      rejection_message: "#{display_name} token was rejected",
    )
  end

  def apply_oauth_token_paste!(access_token:, token_json: nil)
    token = Madcp.sanitize_env_value(access_token)
    raise "Access token is required" if token.empty?

    payload = parse_token_json_paste(token_json) || {}
    payload = payload.merge("access_token" => token)
    store_oauth_token_payload!(
      payload,
      rejection_message: "#{display_name} token was rejected",
    )
  end

  def issuer_url
    "#{Madcp.public_url}/servers/#{code}"
  end

  def mcp_url
    "#{issuer_url}/mcp"
  end

  private

  def parse_json_attr(raw)
    return {} if raw.blank?
    return raw if raw.is_a?(Hash)

    JSON.parse(raw)
  rescue JSON::ParserError
    {}
  end

  def normalize_token_refresh_in_minutes
    self.token_refresh_in_minutes = nil unless token_refresh_in_minutes.to_i.positive?
  end

  def prepare_runtime
    return if @runtime_prepared

    @runtime_prepared = true
    @configured = false
    @tools = []
    @resources = []
    load_credentials! if code.present?
  end
end
