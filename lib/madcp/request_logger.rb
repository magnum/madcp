# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Madcp
  # Dual request logger: compact lines to a file, fuller lines (with response) to stdout.
  class RequestLogger
    SENSITIVE_KEYS = %w[
      authorization password token access_token refresh_token client_secret
      api_token credentials credentials_json toggltrack_token hey_token
      basecamp_token fattureincloud_token googleworkspace_token
      googleworkspace_credentials_json
    ].freeze

    def initialize(path:, io: $stdout, max_chars: 8_000)
      @path = path
      @io = io
      @max_chars = max_chars.positive? ? max_chars : 8_000
      @mutex = Mutex.new
      FileUtils.mkdir_p(File.dirname(@path))
    end

    def log(ip:, method:, path:, status:, duration_ms:, user_agent: nil, request_body: nil, response_body: nil)
      timestamp = Time.now.utc.iso8601(3)
      call = "#{method} #{path}"
      base = {
        ts: timestamp,
        ip: ip.to_s,
        method: method.to_s,
        path: path.to_s,
        status: status.to_i,
        duration_ms: duration_ms.to_i,
      }
      base[:ua] = user_agent.to_s unless user_agent.to_s.empty?
      base[:request] = summarize_payload(request_body) unless blank?(request_body)

      file_line = format_line(base)
      stdout_line = format_line(
        base.merge(response: summarize_payload(response_body)),
      )

      @mutex.synchronize do
        File.open(@path, "a") do |file|
          file.flock(File::LOCK_EX)
          file.puts(file_line)
        end
        @io.puts(stdout_line)
        @io.flush if @io.respond_to?(:flush)
      end
    rescue StandardError => e
      warn("[madcp] request log failed: #{e.class}: #{e.message}")
    end

    private

    def format_line(fields)
      "madcp.request " + fields.map { |key, value| "#{key}=#{quote(value)}" }.join(" ")
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

    def summarize_payload(value)
      return nil if blank?(value)

      text = value.is_a?(String) ? value : JSON.generate(value)
      redacted = redact_text(text)
      truncate(redacted)
    rescue StandardError
      truncate(value.to_s)
    end

    def redact_text(text)
      begin
        parsed = JSON.parse(text)
        return JSON.generate(redact_value(parsed))
      rescue JSON::ParserError
        # fall through to header-style redaction
      end

      text
        .gsub(/(Authorization:\s*)\S+/i, "\\1[REDACTED]")
        .gsub(/("?(?:#{SENSITIVE_KEYS.join("|")})"?\s*[:=]\s*)(".*?"|'.*?'|[^\s,&]+)/i, "\\1[REDACTED]")
    end

    def redact_value(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          out[key] =
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
