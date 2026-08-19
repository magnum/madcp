# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "uri"

module Emcp
  module Servers
    module Twitter
      class Client
        API_BASE = "https://api.twitter.com/2"
        TOKEN_URL = "https://api.twitter.com/2/oauth2/token"
        SAFE_RESPONSE_HEADERS = %w[
          content-type cache-control date x-rate-limit-limit x-rate-limit-remaining
          x-rate-limit-reset retry-after
        ].freeze
        SENSITIVE_BODY_KEYS = %w[access_token refresh_token client_secret].freeze

        class Error < StandardError; end

        def initialize(
          token: nil,
          timeout: ENV.fetch("TWITTER_TIMEOUT", "30").to_i,
          max_chars: ENV.fetch("EMCP_MAX_CHARS", "100000").to_i,
          on_token_refresh: nil
        )
          @token_override = token
          @timeout = timeout.positive? ? timeout : 30
          @max_chars = max_chars.positive? ? max_chars : 12_000
          @on_token_refresh = on_token_refresh
        end

        def get(path, query: {}, raise_on_error: true) = request(:get, path, query: query, raise_on_error: raise_on_error)
        def post(path, body: nil, query: {}, raise_on_error: true) = request(:post, path, query: query, body: body, raise_on_error: raise_on_error)
        def delete(path, query: {}, raise_on_error: true) = request(:delete, path, query: query, raise_on_error: raise_on_error)
        def put(path, body: nil, query: {}, raise_on_error: true) = request(:put, path, query: query, body: body, raise_on_error: raise_on_error)

        def request(method, path, query: {}, body: nil, headers: {}, raise_on_error: true, retrying: false)
          token = access_token
          raise Error, "Twitter access token is not configured" if token.empty?
          raise Error, "request body must be a JSON object" if body && !body.is_a?(Hash)

          uri = URI.join("#{API_BASE}/", path.to_s.sub(%r{\A/+}, ""))
          values = query.to_h.reject { |_, value| value.nil? || value == "" }
          uri.query = URI.encode_www_form(flatten_query(values)) unless values.empty?
          request_class = {
            get: Net::HTTP::Get,
            post: Net::HTTP::Post,
            put: Net::HTTP::Put,
            delete: Net::HTTP::Delete,
          }.fetch(method.to_sym)
          http_request = request_class.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/json" if body
          http_request["Authorization"] = "Bearer #{token}"
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

          if response.code.to_i == 401 && !retrying && refresh_access_token!
            return request(
              method,
              path,
              query: query,
              body: body,
              headers: headers,
              raise_on_error: raise_on_error,
              retrying: true,
            )
          end

          result = response_result(response)
          if raise_on_error && !response.is_a?(Net::HTTPSuccess)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Twitter API #{result[:status]}: #{detail}"
          end
          result
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Twitter request failed: #{e.message}"
        end

        def exchange_code(callback_url:, code:, code_verifier:)
          client_id = Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_ID"])
          client_secret = Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_SECRET"])
          raise Error, "TWITTER_CLIENT_ID is required" if client_id.empty?
          raise Error, "TWITTER_CLIENT_SECRET is required" if client_secret.empty?
          raise Error, "OAuth code is required" if code.to_s.empty?
          raise Error, "PKCE code_verifier is required" if code_verifier.to_s.empty?

          form_token_request(
            {
              grant_type: "authorization_code",
              code: code,
              redirect_uri: callback_url,
              code_verifier: code_verifier,
              client_id: client_id,
            },
            client_id: client_id,
            client_secret: client_secret,
          )
        end

        def refresh_access_token!
          refresh = Emcp.sanitize_env_value(ENV["TWITTER_REFRESH_TOKEN"])
          return false if refresh.empty?

          client_id = Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_ID"])
          client_secret = Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_SECRET"])
          return false if client_id.empty? || client_secret.empty?

          result = form_token_request(
            {
              grant_type: "refresh_token",
              refresh_token: refresh,
              client_id: client_id,
            },
            client_id: client_id,
            client_secret: client_secret,
            raise_on_error: false,
          )
          return false unless result[:status].between?(200, 299)

          body = result[:body].is_a?(Hash) ? result[:body] : {}
          access = Emcp.sanitize_env_value(body["access_token"])
          return false if access.empty?

          new_refresh = Emcp.sanitize_env_value(body["refresh_token"])
          new_refresh = refresh if new_refresh.empty?
          ENV["TWITTER_TOKEN"] = access
          ENV["TWITTER_REFRESH_TOKEN"] = new_refresh
          @on_token_refresh&.call(access_token: access, refresh_token: new_refresh, body: body)
          true
        rescue Error
          false
        end

        private

        def access_token
          raw = @token_override.nil? ? ENV["TWITTER_TOKEN"] : @token_override
          Emcp.sanitize_env_value(raw)
        end

        def form_token_request(form, client_id:, client_secret:, raise_on_error: true)
          uri = URI(TOKEN_URL)
          http_request = Net::HTTP::Post.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/x-www-form-urlencoded"
          http_request["Authorization"] = "Basic #{Base64.strict_encode64("#{client_id}:#{client_secret}")}"
          http_request.body = URI.encode_www_form(form)

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }
          # Do not redact token endpoint bodies: apply_oauth_result! needs access_token.
          result = response_result(response, redact: false)
          if raise_on_error && !response.is_a?(Net::HTTPSuccess)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Twitter OAuth token #{result[:status]}: #{detail}"
          end
          result
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Twitter OAuth token request failed: #{e.message}"
        end

        def flatten_query(values)
          values.flat_map do |key, value|
            if value.is_a?(Array)
              value.map { |item| [key.to_s, item] }
            else
              [[key.to_s, value]]
            end
          end
        end

        def response_result(response, redact: true)
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
            body: redact ? redact_sensitive(parsed) : parsed,
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
