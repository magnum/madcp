# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Madcp
  module Servers
    module FattureInCloud
      class Client
        API_BASE = "https://api-v2.fattureincloud.it"
        SAFE_RESPONSE_HEADERS = %w[
          content-type cache-control date request-id x-request-id
          x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset retry-after
        ].freeze

        class Error < StandardError; end

        def initialize(
          token: nil,
          timeout: ENV.fetch("FATTUREINCLOUD_TIMEOUT", "30").to_i,
          max_chars: ENV.fetch("MADCP_MAX_CHARS", "100000").to_i,
          on_token_refresh: nil
        )
          # nil means "read FATTUREINCLOUD_TOKEN from ENV on each request" so
          # refreshes applied after boot are visible without rebuilding the client.
          @token_override = token
          @timeout = timeout.positive? ? timeout : 30
          @max_chars = max_chars.positive? ? max_chars : 12_000
          @on_token_refresh = on_token_refresh
          @refresh_mutex = Mutex.new
        end

        def get(path, query: {}) = request(:get, path, query: query)
        def post(path, body:, query: {}) = request(:post, path, query: query, body: body)
        def put(path, body:, query: {}) = request(:put, path, query: query, body: body)
        def delete(path, body: nil, query: {}) = request(:delete, path, query: query, body: body)

        def request(method, path, query: {}, body: nil, headers: {}, bearer: true, base_url: API_BASE, raise_on_error: true, retrying: false)
          token = access_token
          raise Error, "Fatture in Cloud access token is not configured" if bearer && token.empty?
          raise Error, "request body must be a JSON object" if body && !body.is_a?(Hash)

          uri = URI.join("#{base_url}/", path.to_s.sub(%r{\A/+}, ""))
          values = query.to_h.reject { |_, value| value.nil? || value == "" }
          uri.query = URI.encode_www_form(values) unless values.empty?
          request_class = {
            get: Net::HTTP::Get,
            post: Net::HTTP::Post,
            put: Net::HTTP::Put,
            delete: Net::HTTP::Delete,
          }.fetch(method.to_sym)
          http_request = request_class.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/json" if body
          http_request["Authorization"] = "Bearer #{token}" if bearer
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

          if bearer && response.code.to_i == 401 && !retrying && refresh_access_token!
            return request(
              method,
              path,
              query: query,
              body: body,
              headers: headers,
              bearer: bearer,
              base_url: base_url,
              raise_on_error: raise_on_error,
              retrying: true,
            )
          end

          result = response_result(response)
          if raise_on_error && !response.is_a?(Net::HTTPSuccess)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Fatture in Cloud API #{result[:status]}: #{detail}"
          end
          result
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Fatture in Cloud request failed: #{e.message}"
        end

        def refresh_access_token!
          @refresh_mutex.synchronize do
            refresh = Madcp.sanitize_env_value(ENV["FATTUREINCLOUD_REFRESH_TOKEN"])
            return false if refresh.empty?

            client_id = Madcp.sanitize_env_value(ENV["FATTUREINCLOUD_CLIENT_ID"])
            client_secret = Madcp.sanitize_env_value(ENV["FATTUREINCLOUD_CLIENT_SECRET"])
            return false if client_id.empty? || client_secret.empty?

            result = request(
              :post,
              "/oauth/token",
              bearer: false,
              raise_on_error: false,
              retrying: true,
              body: {
                grant_type: "refresh_token",
                client_id: client_id,
                client_secret: client_secret,
                refresh_token: refresh,
              },
            )
            return false unless result[:status].between?(200, 299)

            body = result[:body].is_a?(Hash) ? result[:body] : {}
            access = Madcp.sanitize_env_value(body["access_token"] || body[:access_token])
            return false if access.empty?

            new_refresh = Madcp.sanitize_env_value(body["refresh_token"] || body[:refresh_token])
            new_refresh = refresh if new_refresh.empty?
            ENV["FATTUREINCLOUD_TOKEN"] = access
            ENV["FATTUREINCLOUD_REFRESH_TOKEN"] = new_refresh
            @on_token_refresh&.call(access_token: access, refresh_token: new_refresh, body: body)
            true
          end
        rescue Error
          false
        end

        private

        def access_token
          raw = @token_override.nil? ? ENV["FATTUREINCLOUD_TOKEN"] : @token_override
          Madcp.sanitize_env_value(raw)
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
            body: parsed,
          }
        rescue JSON::ParserError
          {
            status: response.code.to_i,
            headers: response.each_header.to_h.slice(*SAFE_RESPONSE_HEADERS),
            body: output,
          }
        end
      end
    end
  end
end
