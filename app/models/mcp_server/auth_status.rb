# frozen_string_literal: true

module McpServer::AuthStatus
  extend ActiveSupport::Concern

  def auth_status(force: false)
    ttl = auth_status_cache_ttl.to_i
    unless force
      cached = read_auth_status_cache(ttl)
      return cached if cached
    end

    status = fetch_auth_status
    write_auth_status_cache(status, ttl)
    status
  end

  def invalidate_auth_status!
    @auth_status_cache = nil
    @auth_status_cached_at = nil
  end

  def auth_status_cache_ttl = 0
  def fetch_auth_status = { authenticated: false }

  def auth_field_value(field)
    raw =
      if field.key?(:value)
        value = field[:value]
        value = instance_exec(&value) if value.respond_to?(:call)
        value
      elsif field[:env]
        ENV[field[:env]]
      end
    Emcp.sanitize_env_value(raw)
  end

  private

  def read_auth_status_cache(ttl)
    return nil unless ttl.positive?
    return nil unless @auth_status_cache && @auth_status_cached_at

    age = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @auth_status_cached_at
    return nil if age >= ttl

    @auth_status_cache
  end

  def write_auth_status_cache(status, ttl)
    return unless ttl.positive?

    @auth_status_cache = status
    @auth_status_cached_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
