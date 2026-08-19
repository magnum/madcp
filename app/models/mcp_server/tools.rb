# frozen_string_literal: true

module McpServer::Tools
  extend ActiveSupport::Concern

  def tool_catalog
    configure_once!
    tools.map do |tool|
      {
        name: tool.name,
        description: tool.description,
        input_schema: tool.input_schema,
        write: tool.write,
        enabled: !tool.write || allow_write_methods?,
      }
    end
  end

  def call_tool(name, arguments = {})
    configure_once!
    definition = tools.find { |candidate| candidate.name == name }
    raise KeyError, "unknown tool: #{name}" unless definition
    raise SecurityError, "write method disabled" if definition.write && !allow_write_methods?

    instance_exec(**filter_tool_arguments(definition, arguments), &definition.handler)
  end

  def mcp_protocol_server
    configure_once!
    @mcp_protocol_server ||= build_mcp_protocol_server
  end

  def handle_mcp_json(body)
    mcp_protocol_server.handle_json(body)
  end

  protected

  def define_tool(name:, description:, properties: {}, required: [], write: false, &handler)
    tools << Emcp::ToolDefinition.new(
      name: name,
      description: description,
      input_schema: { properties: properties, required: required },
      write: write,
      handler: handler,
    )
  end

  def define_resource(uri:, name:, description:, mime_type: "text/plain", &handler)
    resources << Emcp::ResourceDefinition.new(
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
  rescue Emcp::CliError => e
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

  private

  def tools
    @tools ||= []
  end

  def resources
    @resources ||= []
  end

  def configure_once!
    return if @configured

    configure_tools
    @configured = true
  end

  def filter_tool_arguments(definition, arguments)
    allowed = definition.input_schema.fetch(:properties, {}).keys.map(&:to_sym)
    arguments.to_h.transform_keys(&:to_sym).select { |key, _| allowed.include?(key) }
  end

  def build_mcp_protocol_server
    integration = self
    server = MCP::Server.new(
      name: code,
      version: version,
      instructions: instructions,
      resources: resources.map do |resource|
        MCP::Resource.new(
          uri: resource.uri,
          name: resource.name,
          description: resource.description,
          mime_type: resource.mime_type,
        )
      end,
    )
    unless resources.empty?
      server.resources_read_handler do |params|
        uri = params[:uri]
        resource = resources.find { |candidate| candidate.uri == uri }
        raise KeyError, "unknown resource: #{uri}" unless resource

        [{
          uri: resource.uri,
          mimeType: resource.mime_type,
          text: resource.handler.call,
        }]
      end
    end
    tools.each do |definition|
      server.define_tool(
        name: definition.name,
        description: definition.description,
        input_schema: definition.input_schema,
      ) do |**arguments|
        if definition.write && !integration.allow_write_methods?
          integration.send(
            :text_response,
            "ERROR: write method disabled. Set #{integration.code.upcase}_ALLOW_WRITE=true or mcp_server.allow_write.",
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
