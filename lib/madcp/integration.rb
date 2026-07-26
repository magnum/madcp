# frozen_string_literal: true

require "fileutils"
require "json"
require "mcp"

module Madcp
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
                "ERROR: write method disabled. Set MADCP_#{integration.id.upcase}_ALLOW_WRITE_METHODS=true.",
              )
            else
              allowed = definition.input_schema.fetch(:properties, {}).keys.map(&:to_sym)
              tool_arguments = arguments.select { |key, _| allowed.include?(key.to_sym) }
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

      allowed = definition.input_schema.fetch(:properties, {}).keys.map(&:to_sym)
      tool_arguments = arguments.to_h.transform_keys(&:to_sym).select do |key, _|
        allowed.include?(key)
      end
      instance_exec(**tool_arguments, &definition.handler)
    end

    # Integration contract -------------------------------------------------

    def instructions = "#{display_name} MCP integration."
    def auth_fields = []
    def auth_status = { authenticated: false }
    def apply_credentials(_params) = raise(NotImplementedError)
    def clear_credentials! = raise(NotImplementedError)
    def configure_tools = raise(NotImplementedError)
    def oauth_call(callback_url:, state:) = raise(NotImplementedError)
    def oauth_exchange(callback_url:, params:) = raise(NotImplementedError)

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

    def cli_response(client, args)
      text_response(client.run(args))
    rescue CliError => e
      text_response("ERROR: #{e.message}")
    end

    def credential_path
      File.join(data_dir, "credentials.env")
    end

    def load_credentials!
      return unless File.file?(credential_path)

      File.readlines(credential_path, chomp: true).each do |line|
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        ENV[key] = value if key && value && credential_env_keys.include?(key)
      end
    end

    def persist_credentials!(values)
      current = credential_env_keys.to_h { |key| [key, ENV[key]] }.compact
      values.each do |key, value|
        key = key.to_s
        next unless credential_env_keys.include?(key)

        if value.to_s.empty?
          current.delete(key)
          ENV.delete(key)
        else
          current[key] = value.to_s
          ENV[key] = value.to_s
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
    end

    def credential_env_keys = []

    def string_prop(description) = { type: "string", description: description }
    def integer_prop(description) = { type: "integer", description: description }
    def boolean_prop(description) = { type: "boolean", description: description }
    def array_prop(description) = { type: "array", items: { type: "string" }, description: description }

    private

    def configure_once!
      return if @configured

      configure_tools
      @configured = true
    end
  end
end
