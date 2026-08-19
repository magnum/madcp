# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Emcp
  # Compact request logger (file + stdout). No response bodies.
  class RequestLogger
    SENSITIVE_KEYS = %w[
      authorization password token access_token refresh_token client_secret
      api_token credentials credentials_json toggltrack_token hey_token
      basecamp_token fattureincloud_token googleworkspace_token
      googleworkspace_credentials_json
    ].freeze

    def initialize(path:, io: $stdout, max_chars: 2_000)
      @path = path
      @io = io
      @max_chars = max_chars.positive? ? max_chars : 2_000
      @mutex = Mutex.new
      FileUtils.mkdir_p(File.dirname(@path))
    end

    def log(ip:, method:, path:, status:, duration_ms:, user_agent: nil, request_body: nil)
      fields = {
        ts: Time.now.utc.iso8601(3),
        ip: ip.to_s,
        method: method.to_s,
        path: path.to_s,
        status: status.to_i,
        duration_ms: duration_ms.to_i,
      }
      fields[:ua] = user_agent.to_s unless user_agent.to_s.empty?

      details = extract_call_details(path, request_body)
      fields.merge!(details)
      line = format_line(fields)

      @mutex.synchronize do
        File.open(@path, "a") do |file|
          file.flock(File::LOCK_EX)
          file.puts(line)
        end
        @io.puts(line)
        @io.flush if @io.respond_to?(:flush)
      end
    rescue StandardError => e
      warn("[emcp] request log failed: #{e.class}: #{e.message}")
    end

    private

    def extract_call_details(path, request_body)
      details = {}
      if (match = path.to_s.match(%r{\A/servers/([^/?#]+)}))
        details[:server_id] = match[1]
      end

      payload = parse_json_object(request_body)
      return details if payload.nil?

      if payload["jsonrpc"] || payload[:jsonrpc]
        # MCP JSON-RPC: method + params; tools/call uses params.name + params.arguments
        mcp_method = payload["method"] || payload[:method]
        details[:mcp_method] = mcp_method.to_s unless mcp_method.to_s.empty?

        params = payload["params"] || payload[:params] || {}
        params = params.to_h.transform_keys(&:to_s)
        if mcp_method.to_s == "tools/call"
          command = params["name"].to_s
          details[:command] = command unless command.empty?
          arguments = params["arguments"]
          details[:arguments] = redact_value(arguments) unless blank?(arguments)
        else
          details[:params] = redact_value(params) unless blank?(params)
        end
      elsif (match = path.to_s.match(%r{\A/servers/[^/]+/tools/([^/?#]+)}))
        details[:command] = match[1]
        details[:params] = redact_value(payload) unless blank?(payload)
      else
        details[:params] = redact_value(payload) unless blank?(payload)
      end

      details
    end

    def parse_json_object(value)
      return nil if blank?(value)
      return value if value.is_a?(Hash)

      parsed = JSON.parse(value.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def format_line(fields)
      "emcp.request " + fields.map { |key, value| "#{key}=#{quote(value)}" }.join(" ")
    end

    def quote(value)
      text =
        case value
        when String then value
        when NilClass then ""
        else JSON.generate(value)
        end
      text = truncate(text)
      return text if text.match?(/\A[\w.\/:+-]+\z/)

      text.dump
    end

    def redact_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          out[key.to_s] =
            if SENSITIVE_KEYS.include?(key.to_s.downcase)
              "[REDACTED]"
            else
              redact_value(item)
            end
        end
      when Array
        value.map { |item| redact_value(item) }
      else
        value
      end
    end

    def truncate(text)
      text = text.to_s
      return text if text.length <= @max_chars

      "#{text[0, @max_chars]}…[truncated #{text.length - @max_chars} chars]"
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end
  end
end
