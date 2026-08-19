# frozen_string_literal: true

require "fileutils"
require "json"
require "mcp"

module Emcp
  ToolDefinition = Data.define(:name, :description, :input_schema, :write, :handler)
  ResourceDefinition = Data.define(:uri, :name, :description, :mime_type, :handler)

  class Integration
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
    end

    attr_reader :config, :tools

    def initialize(config:)
      @config = config
      @tools = []
      @resources = []
      @configured = false
      @auth_status_cache = nil
      @auth_status_cached_at = nil
      FileUtils.mkdir_p(data_dir)
      load_credentials!
    end

    def id = self.class.server_id
    def display_name = self.class.display_name
    def description = self.class.description
    def version = self.class.version
    def data_dir = config.data_dir(id)
    def allow_write_methods? = config.write_allowed_for?(id)
    def oauth_token_retrieval? = self.class.oauth_token_retrieval

    def mcp_server
      configure_once!
      @mcp_server ||= begin
        integration = self
        server = MCP::Server.new(
          name: id,
          version: version,
          instructions: instructions,
          resources: @resources.map do |resource|
            MCP::Resource.new(
              uri: resource.uri,
              name: resource.name,
              description: resource.description,
              mime_type: resource.mime_type,
            )
          end,
        )
        unless @resources.empty?
          server.resources_read_handler do |params|
            uri = params[:uri]
            resource = @resources.find { |candidate| candidate.uri == uri }
            raise KeyError, "unknown resource: #{uri}" unless resource

            [{
              uri: resource.uri,
              mimeType: resource.mime_type,
              text: resource.handler.call,
            }]
          end
        end
        @tools.each do |definition|
          server.define_tool(
            name: definition.name,
            description: definition.description,
            input_schema: definition.input_schema,
          ) do |**arguments|
            if definition.write && !integration.allow_write_methods?
              integration.send(
                :text_response,
                "ERROR: write method disabled. Set #{integration.id.upcase}_ALLOW_WRITE=true.",
              )
            else
              tool_arguments = integration.send(:filter_tool_arguments, definition, arguments)
              integration.instance_exec(**tool_arguments, &definition.handler)
            end
          rescue StandardError => e
            integration.send(:text_response, "ERROR: #{e.message}")
          end
        end
        server
      end
    end

    def tool_catalog
      configure_once!
      @tools.map do |tool|
        {
          name: tool.name,
          description: tool.description,
          input_schema: tool.input_schema,
          write: tool.write,
          enabled: !tool.write || allow_write_methods?,
        }
      end
    end

    def call_tool(name, arguments)
      configure_once!
      definition = @tools.find { |candidate| candidate.name == name }
      raise KeyError, "unknown tool: #{name}" unless definition
      raise SecurityError, "write method disabled" if definition.write && !allow_write_methods?

      instance_exec(**filter_tool_arguments(definition, arguments), &definition.handler)
    end

    # Integration contract -------------------------------------------------

    def instructions = "#{display_name} MCP integration."
    def auth_fields = []
    def auth_help_content = nil

    # Public auth status with optional TTL cache. Servers implement the probe in
    # fetch_auth_status; EmCP decides when to reuse a previous result.
    # Pass force: true (manual refresh / credential save) to bypass the cache.
    def auth_status(force: false)
      ttl = auth_status_cache_ttl.to_i
      unless force
        cached = read_auth_status_cache(ttl)
        return cached if cached
      end

      status = fetch_auth_status
      write_auth_status_cache(status, ttl)
      status
    end

    def invalidate_auth_status!
      @auth_status_cache = nil
      @auth_status_cached_at = nil
    end

    # Seconds to reuse a successful/failed probe. 0 disables caching.
    def auth_status_cache_ttl = 0

    # Live provider/CLI check. Override in each integration.
    def fetch_auth_status = { authenticated: false }

    def apply_credentials(_params) = raise(NotImplementedError)
    def clear_credentials! = raise(NotImplementedError)
    def configure_tools = raise(NotImplementedError)
    def oauth_call(callback_url:, state:) = raise(NotImplementedError)
    # state_data is the consumed oauth_retrieval_states entry (may include PKCE
    # fields returned by oauth_call and merged by the host).
    def oauth_exchange(callback_url:, params:, state_data: nil) = raise(NotImplementedError)

    def apply_oauth_result!(result)
      store_oauth_token_payload!(
        oauth_result_body(result),
        rejection_message: "#{display_name} token was rejected",
      )
    end

    def apply_oauth_token_paste!(access_token:, token_json: nil)
      token = Emcp.sanitize_env_value(access_token)
      raise "Access token is required" if token.empty?

      payload = parse_token_json_paste(token_json) || {}
      payload = payload.merge("access_token" => token)
      store_oauth_token_payload!(
        payload,
        rejection_message: "#{display_name} token was rejected",
      )
    end

    # Current value for an auth form field. Prefer an explicit :value (string or
    # callable), otherwise the ENV key named by :env.
    def auth_field_value(field)
      raw =
        if field.key?(:value)
          value = field[:value]
          value = instance_exec(&value) if value.respond_to?(:call)
          value
        elsif field[:env]
          ENV[field[:env]]
        end
      Emcp.sanitize_env_value(raw)
    end

    protected

    def define_tool(name:, description:, properties: {}, required: [], write: false, &handler)
      @tools << ToolDefinition.new(
        name: name,
        description: description,
        input_schema: { properties: properties, required: required },
        write: write,
        handler: handler,
      )
    end

    def define_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
      @resources << ResourceDefinition.new(
        uri: uri,
        name: name,
        description: description,
        mime_type: mime_type,
        handler: handler,
      )
    end

    def text_response(text)
      MCP::Tool::Response.new([{ type: "text", text: text.to_s }])
    end

    def api_response(result = nil)
      payload = block_given? ? yield : result
      text_response(JSON.pretty_generate(payload))
    rescue StandardError => e
      text_response("ERROR: #{e.message}")
    end

    def cli_response(client, args)
      text_response(client.run(args))
    rescue CliError => e
      text_response("ERROR: #{e.message}")
    end

    def object_prop(description)
      { type: "object", description: description, additionalProperties: true }
    end

    def compact_hash(values)
      values.reject { |_, value| value.nil? || value == "" }
    end

    def stringify_keys(values)
      values.to_h.transform_keys(&:to_s)
    end

    def string_prop(description) = { type: "string", description: description }
    def integer_prop(description) = { type: "integer", description: description }
    def boolean_prop(description) = { type: "boolean", description: description }
    def array_prop(description) = { type: "array", items: { type: "string" }, description: description }

    def credential_path
      File.join(data_dir, "credentials.env")
    end

    def load_credentials!
      if File.file?(credential_path)
        File.readlines(credential_path, chomp: true).each do |line|
          next if line.empty? || line.start_with?("#")

          key, value = line.split("=", 2)
          next unless key && value && credential_env_keys.include?(key)

          cleaned = Emcp.sanitize_env_value(value)
          if cleaned.empty?
            ENV.delete(key)
          else
            ENV[key] = cleaned
          end
        end
      end

      sanitize_credential_env!
    end

    def persist_credentials!(values)
      current = credential_env_keys.to_h do |key|
        [key, Emcp.sanitize_env_value(ENV[key])]
      end.reject { |_, value| value.empty? }

      values.each do |key, value|
        key = key.to_s
        next unless credential_env_keys.include?(key)

        cleaned = Emcp.sanitize_env_value(value)
        if cleaned.empty?
          current.delete(key)
          ENV.delete(key)
        else
          current[key] = cleaned
          ENV[key] = cleaned
        end
      end

      if current.empty?
        File.delete(credential_path) if File.file?(credential_path)
      else
        File.write(
          credential_path,
          current.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n",
          perm: 0o600,
        )
      end
      invalidate_auth_status!
    end

    def sanitize_credential_env!
      credential_env_keys.each do |key|
        next unless ENV.key?(key)

        cleaned = Emcp.sanitize_env_value(ENV[key])
        if cleaned.empty?
          ENV.delete(key)
        else
          ENV[key] = cleaned
        end
      end
    end

    def credential_env_keys = []

    # Rebuild HTTP/CLI clients after ENV credentials change. Override in servers.
    def replace_client!
    end

    # Persist updates, probe auth, roll back ENV + client on failure.
    def apply_credentials_probe!(updates, rejection_message:)
      old = credential_env_keys.to_h { |key| [key, ENV[key]] }
      persist_credentials!(updates)
      replace_client!
      status = auth_status(force: true)
      return true if status[:authenticated]

      persist_credentials!(old)
      replace_client!
      detail = status[:error].to_s.strip
      raise(detail.empty? ? rejection_message : "#{rejection_message}: #{detail}")
    end

    # ENV keys for provider OAuth access/refresh tokens (Twitter, Fatture, …).
    def oauth_access_env = nil
    def oauth_refresh_env = nil

    def oauth_token_path
      File.join(data_dir, "oauth_token.json")
    end

    def clear_oauth_token_file!
      File.delete(oauth_token_path) if File.file?(oauth_token_path)
    end

    def oauth_result_body(result)
      raise "Empty OAuth token response" if result.nil?

      body = result.is_a?(Hash) ? (result[:body] || result["body"] || result) : nil
      raise "OAuth token response body is missing" unless body.is_a?(Hash)

      status = result[:status] || result["status"]
      if status && !status.to_i.between?(200, 299)
        raise "OAuth token exchange failed with status #{status}"
      end

      stringify_keys(body)
    end

    def persist_oauth_token_payload!(payload)
      raise "OAuth token payload must be a JSON object" unless payload.is_a?(Hash)

      FileUtils.mkdir_p(File.dirname(oauth_token_path))
      File.write(oauth_token_path, JSON.pretty_generate(payload) + "\n", perm: 0o600)
    end

    def parse_token_json_paste(token_json)
      raw = token_json.to_s.strip
      return nil if raw.empty?

      parsed = JSON.parse(raw)
      raise "token_json must be a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise "invalid token_json: #{e.message}"
    end

    def store_oauth_token_payload!(payload, rejection_message:)
      body = stringify_keys(payload)
      access_token = Emcp.sanitize_env_value(body["access_token"])
      raise "OAuth response did not include an access_token" if access_token.empty?
      raise "oauth_access_env is not configured" if oauth_access_env.to_s.empty?

      persist_oauth_token_payload!(body)
      updates = { oauth_access_env => access_token }
      updates[oauth_refresh_env] = Emcp.sanitize_env_value(body["refresh_token"]) if oauth_refresh_env
      persist_credentials!(updates)
      replace_client!
      raise rejection_message unless auth_status(force: true)[:authenticated]

      true
    end

    def persist_refreshed_oauth_token!(access_token:, refresh_token:, body:)
      persist_oauth_token_payload!(body) if body.is_a?(Hash)
      updates = { oauth_access_env => access_token }
      updates[oauth_refresh_env] = refresh_token if oauth_refresh_env
      persist_credentials!(updates)
    end

    private

    def filter_tool_arguments(definition, arguments)
      allowed = definition.input_schema.fetch(:properties, {}).keys.map(&:to_sym)
      arguments.to_h.transform_keys(&:to_sym).select { |key, _| allowed.include?(key) }
    end

    def configure_once!
      return if @configured

      configure_tools
      @configured = true
    end

    def read_auth_status_cache(ttl)
      return nil unless ttl.positive?
      return nil unless @auth_status_cache && @auth_status_cached_at

      age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @auth_status_cached_at
      return nil if age >= ttl

      @auth_status_cache
    end

    def write_auth_status_cache(status, ttl)
      return unless ttl.positive?

      @auth_status_cache = status
      @auth_status_cached_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
