# frozen_string_literal: true

require "fileutils"
require "json"

module Emcp
  # Durable one-time states for provider OAuth token retrieval
  # (POST /servers/:id/oauth → GET …/oauth_callback).
  # Kept on disk so reloads / single-process restarts do not break in-flight flows.
  class OAuthRetrievalStore
    DEFAULT_TTL = 600

    def initialize(path:)
      @path = path
      @mutex = Mutex.new
      @states = {}
      load!
    end

    def put(state, data)
      @mutex.synchronize do
        purge_expired_locked!
        @states[state.to_s] = stringify_keys(data)
        persist_locked!
        @states[state.to_s]
      end
    end

    def peek(state)
      @mutex.synchronize do
        purge_expired_locked!
        deep_dup(@states[state.to_s])
      end
    end

    # Returns the state payload once, then deletes it.
    def consume(state, server_id:)
      @mutex.synchronize do
        purge_expired_locked!
        key = state.to_s
        data = @states[key]
        return nil unless data
        return nil unless data[:server_id].to_s == server_id.to_s
        return nil if data[:expires_at].to_i < Time.now.to_i

        @states.delete(key)
        persist_locked!
        deep_dup(data)
      end
    end

    private

    def load!
      return unless File.file?(@path)

      raw = JSON.parse(File.read(@path))
      return unless raw.is_a?(Hash)

      @states = raw.each_with_object({}) do |(key, value), out|
        next unless value.is_a?(Hash)

        out[key.to_s] = value.transform_keys(&:to_sym)
      end
      purge_expired_locked!
      persist_locked!
    rescue JSON::ParserError, Errno::ENOENT
      @states = {}
    end

    def purge_expired_locked!
      now = Time.now.to_i
      @states.delete_if { |_, data| data[:expires_at].to_i < now }
    end

    def persist_locked!
      FileUtils.mkdir_p(File.dirname(@path))
      payload = @states.transform_values { |data| data.transform_keys(&:to_s) }
      tmp = "#{@path}.tmp"
      File.write(tmp, JSON.pretty_generate(payload) + "\n", perm: 0o600)
      File.rename(tmp, @path)
    end

    def stringify_keys(data)
      data.to_h.transform_keys(&:to_sym)
    end

    def deep_dup(value)
      case value
      when Hash
        value.transform_values { |item| deep_dup(item) }
      when Array
        value.map { |item| deep_dup(item) }
      else
        value
      end
    end
  end
end
