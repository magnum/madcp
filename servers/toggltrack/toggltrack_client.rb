# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "uri"

module Emcp
  module Servers
    module TogglTrack
      class Client
        API_BASE = "https://api.track.toggl.com/api/v9"
        SAFE_RESPONSE_HEADERS = %w[
          content-type cache-control date
          x-toggl-quota-remaining x-toggl-quota-resets-in
          x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset retry-after
        ].freeze
        # Toggl returns workspace/profile API tokens in cleartext; never forward them to MCP clients.
        SENSITIVE_BODY_KEYS = %w[api_token].freeze

        class Error < StandardError; end

        def initialize(
          token: nil,
          timeout: ENV.fetch("TOGGLTRACK_TIMEOUT", "30").to_i,
          max_chars: ENV.fetch("EMCP_MAX_CHARS", "100000").to_i
        )
          # nil means "read TOGGLTRACK_TOKEN from ENV on each request" so status
          # checks and tools always see credentials saved after boot.
          @token_override = token
          @timeout = timeout.positive? ? timeout : 30
          @max_chars = max_chars.positive? ? max_chars : 12_000
        end

        def get(path, query: {}) = request(:get, path, query: query)
        def post(path, body:, query: {}) = request(:post, path, query: query, body: body)
        def put(path, body:, query: {}) = request(:put, path, query: query, body: body)
        def patch(path, body: nil, query: {}) = request(:patch, path, query: query, body: body)
        def delete(path, body: nil, query: {}) = request(:delete, path, query: query, body: body)

        def request(method, path, query: {}, body: nil, headers: {}, raise_on_error: true)
          token = api_token
          raise Error, "Toggl Track API token is not configured" if token.empty?
          raise Error, "request body must be a JSON object" if body && !body.is_a?(Hash)

          uri = URI.join("#{API_BASE}/", path.to_s.sub(%r{\A/+}, ""))
          values = query.to_h.reject { |_, value| value.nil? || value == "" }
          uri.query = URI.encode_www_form(values) unless values.empty?
          request_class = {
            get: Net::HTTP::Get,
            post: Net::HTTP::Post,
            put: Net::HTTP::Put,
            patch: Net::HTTP::Patch,
            delete: Net::HTTP::Delete,
          }.fetch(method.to_sym)
          http_request = request_class.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/json" if body
          http_request["Authorization"] = "Basic #{Base64.strict_encode64("#{token}:api_token")}"
          headers.each { |key, value| http_request[key.to_s] = value.to_s }
          http_request.body = JSON.generate(body) if body

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }
          result = response_result(response)
          if raise_on_error && !response.is_a?(Net::HTTPSuccess)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Toggl Track API #{result[:status]}: #{detail}"
          end
          result
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Toggl Track request failed: #{e.message}"
        end

        private

        def api_token
          raw = @token_override.nil? ? ENV["TOGGLTRACK_TOKEN"] : @token_override
          Emcp.sanitize_env_value(raw)
        end

        def response_result(response)
          raw = response.body.to_s
          truncated = raw.length > @max_chars
          output = truncated ? "#{raw[0, @max_chars]}\n...[truncated]" : raw
          parsed = if truncated
                     output
                   elsif output.empty?
                     nil
                   else
                     JSON.parse(output)
                   end
          {
            status: response.code.to_i,
            headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS),
            body: redact_sensitive(parsed),
          }
        rescue JSON::ParserError
          {
            status: response.code.to_i,
            headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS),
            body: output,
          }
        end

        def redact_sensitive(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), out|
              out[key] =
                if SENSITIVE_BODY_KEYS.include?(key.to_s)
                  "[REDACTED]"
                else
                  redact_sensitive(item)
                end
            end
          when Array
            value.map { |item| redact_sensitive(item) }
          else
            value
          end
        end
      end
    end
  end
end
