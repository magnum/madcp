# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Madcp
  module Servers
    module Bluesky
      class Client
        DEFAULT_PDS = "https://bsky.social"
        SAFE_RESPONSE_HEADERS = %w[
          content-type cache-control date ratelimit-limit ratelimit-remaining
          ratelimit-reset ratelimit-policy retry-after
        ].freeze
        SENSITIVE_BODY_KEYS = %w[
          accessJwt refreshJwt access_jwt refresh_jwt password appPassword
        ].freeze

        class Error < StandardError; end

        def initialize(
          pds_host: nil,
          timeout: ENV.fetch("BLUESKY_TIMEOUT", "30").to_i,
          max_chars: ENV.fetch("MADCP_MAX_CHARS", "100000").to_i,
          on_session: nil
        )
          @pds_host_override = pds_host
          @timeout = timeout.positive? ? timeout : 30
          @max_chars = max_chars.positive? ? max_chars : 12_000
          @on_session = on_session
          @session_mutex = Mutex.new
        end

        def get(nsid, query: {}, auth: true, raise_on_error: true)
          request(:get, nsid, query: query, auth: auth, raise_on_error: raise_on_error)
        end

        def post(nsid, body: {}, query: {}, auth: true, raise_on_error: true)
          request(:post, nsid, query: query, body: body, auth: auth, raise_on_error: raise_on_error)
        end

        def ensure_session!
          @session_mutex.synchronize do
            return session_snapshot unless access_jwt.empty?

            create_session!
            session_snapshot
          end
        end

        def request(method, nsid, query: {}, body: nil, auth: true, raise_on_error: true, retrying: false)
          ensure_session! if auth
          raise Error, "request body must be a JSON object" if body && !body.is_a?(Hash)

          uri = URI.join("#{pds_base}/", "xrpc/#{nsid}")
          values = query.to_h.reject { |_, value| value.nil? || value == "" }
          uri.query = URI.encode_www_form(flatten_query(values)) unless values.empty?
          request_class = {
            get: Net::HTTP::Get,
            post: Net::HTTP::Post,
          }.fetch(method.to_sym)
          http_request = request_class.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/json" if body
          http_request["Authorization"] = "Bearer #{access_jwt}" if auth
          http_request.body = JSON.generate(body) if body

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }

          # AT Proto returns ExpiredToken as HTTP 400 (sometimes 401). Match @atproto/api.
          if auth && !retrying && session_expired_response?(response)
            @session_mutex.synchronize { refresh_session! }
            return request(
              method,
              nsid,
              query: query,
              body: body,
              auth: auth,
              raise_on_error: raise_on_error,
              retrying: true,
            )
          end

          result = response_result(response)
          if raise_on_error && !response.is_a?(Net::HTTPSuccess)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Bluesky API #{result[:status]}: #{detail}"
          end
          result
        rescue Timeout::Error, SocketError, SystemCallError => e
          raise Error, "Bluesky request failed: #{e.message}"
        end

        def create_session!
          identifier = Madcp.sanitize_env_value(ENV["BLUESKY_HANDLE"])
          password = Madcp.sanitize_env_value(ENV["BLUESKY_APP_PASSWORD"])
          raise Error, "Bluesky handle is not configured" if identifier.empty?
          raise Error, "Bluesky app password is not configured" if password.empty?

          result = raw_request(
            :post,
            "com.atproto.server.createSession",
            body: { identifier: identifier, password: password },
            auth: false,
          )
          unless result[:status].between?(200, 299)
            detail = result[:body].is_a?(String) ? result[:body] : JSON.generate(result[:body])
            raise Error, "Bluesky createSession failed #{result[:status]}: #{detail}"
          end
          apply_session!(result[:body])
        end

        def refresh_session!
          token = refresh_jwt
          raise Error, "Bluesky refresh token is not configured" if token.empty?

          result = raw_request(
            :post,
            "com.atproto.server.refreshSession",
            auth_token: token,
          )
          return create_session! unless result[:status].between?(200, 299)

          apply_session!(result[:body])
        end

        def did
          Madcp.sanitize_env_value(ENV["BLUESKY_DID"])
        end

        def handle
          Madcp.sanitize_env_value(ENV["BLUESKY_HANDLE"])
        end

        private

        def pds_base
          host = @pds_host_override
          host = ENV["BLUESKY_PDS_HOST"] if host.nil?
          host = DEFAULT_PDS if Madcp.sanitize_env_value(host).empty?
          Madcp.sanitize_env_value(host).sub(%r{/\z}, "")
        end

        def access_jwt
          Madcp.sanitize_env_value(ENV["BLUESKY_ACCESS_JWT"])
        end

        def refresh_jwt
          Madcp.sanitize_env_value(ENV["BLUESKY_REFRESH_JWT"])
        end

        def session_expired_response?(response)
          code = response.code.to_i
          return true if code == 401
          return false unless code == 400

          body = parse_json_object(response.body.to_s)
          return false unless body

          %w[ExpiredToken InvalidToken].include?(body["error"].to_s)
        end

        def parse_json_object(raw)
          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end

        def session_snapshot
          { did: did, handle: handle, access_jwt: access_jwt, refresh_jwt: refresh_jwt }
        end

        def apply_session!(body)
          body = body.is_a?(Hash) ? body : {}
          access = Madcp.sanitize_env_value(body["accessJwt"] || body[:accessJwt])
          refresh = Madcp.sanitize_env_value(body["refreshJwt"] || body[:refreshJwt])
          account_did = Madcp.sanitize_env_value(body["did"] || body[:did])
          account_handle = Madcp.sanitize_env_value(body["handle"] || body[:handle])
          raise Error, "Bluesky session response missing accessJwt" if access.empty?
          raise Error, "Bluesky session response accessJwt was redacted" if access == "[REDACTED]"

          ENV["BLUESKY_ACCESS_JWT"] = access
          ENV["BLUESKY_REFRESH_JWT"] = refresh unless refresh.empty?
          ENV["BLUESKY_DID"] = account_did unless account_did.empty?
          ENV["BLUESKY_HANDLE"] = account_handle unless account_handle.empty?
          @on_session&.call(
            access_jwt: access,
            refresh_jwt: refresh,
            did: account_did,
            handle: account_handle,
          )
        end

        def raw_request(method, nsid, body: nil, auth: true, auth_token: nil)
          uri = URI.join("#{pds_base}/", "xrpc/#{nsid}")
          request_class = method == :get ? Net::HTTP::Get : Net::HTTP::Post
          http_request = request_class.new(uri)
          http_request["Accept"] = "application/json"
          http_request["Content-Type"] = "application/json" if body
          token = auth_token || (auth ? access_jwt : nil)
          http_request["Authorization"] = "Bearer #{token}" if token && !token.empty?
          http_request.body = JSON.generate(body) if body
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: @timeout,
            read_timeout: @timeout,
            write_timeout: @timeout,
          ) { |http| http.request(http_request) }
          # Session endpoints return JWTs that apply_session! must persist unredacted.
          response_result(response, redact: false)
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
