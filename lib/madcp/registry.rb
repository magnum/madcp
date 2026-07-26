# frozen_string_literal: true

module Madcp
  class Registry
    def initialize(config:)
      @config = config
      @integrations = {}
    end

    def discover!(servers_dir)
      Dir.glob(File.join(servers_dir, "*", "server.rb")).sort.each do |path|
        require path
      end
      raise "no integrations registered under #{servers_dir}" if Madcp.integration_classes.empty?

      Madcp.integration_classes.each { |klass| register(klass) }
      self
    end

    def register(integration_class)
      id = integration_class.server_id
      raise "integration class missing server_id: #{integration_class}" if id.to_s.empty?
      raise "duplicate server_id: #{id}" if @integrations.key?(id)

      @integrations[id] = integration_class.new(config: @config)
    end

    def fetch(id)
      @integrations.fetch(id) { raise KeyError, "unknown server: #{id}" }
    end

    def all
      @integrations.values
    end

    def catalog
      all.map do |integration|
        item = {
          id: integration.id,
          name: integration.display_name,
          description: integration.description,
          version: integration.version,
          authenticated: integration.auth_status[:authenticated],
          allow_write_methods: integration.allow_write_methods?,
          mcp_url: "#{@config.public_url}/servers/#{integration.id}/mcp",
          auth_url: "#{@config.public_url}/servers/#{integration.id}/auth",
          tools_url: "#{@config.public_url}/servers/#{integration.id}/tools",
        }
        if integration.oauth_token_retrieval?
          item[:oauth_retrieval_url] = "#{@config.public_url}/servers/#{integration.id}/oauth"
          item[:oauth_callback_url] = "#{@config.public_url}/servers/#{integration.id}/oauth_callback"
        end
        item
      end
    end
  end

  class << self
    def register_integration(klass)
      integration_classes << klass unless integration_classes.include?(klass)
    end

    def integration_classes
      @integration_classes ||= []
    end
  end
end
