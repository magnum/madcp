# frozen_string_literal: true

module McpServer::Credentials
  extend ActiveSupport::Concern

  def data_dir
    path = Rails.root.join("storage", "mcp", code)
    FileUtils.mkdir_p(path)
    path.to_s
  end

  def credential_path
    File.join(data_dir, "credentials.env")
  end

  def oauth_token_path
    File.join(data_dir, "oauth_token.json")
  end

  def load_credentials!
    stored = credential_hash
    stored.each do |key, value|
      next unless credential_env_keys.include?(key)

      cleaned = Emcp.sanitize_env_value(value)
      if cleaned.empty?
        ENV.delete(key)
      else
        ENV[key] = cleaned
      end
    end

    if File.file?(credential_path)
      File.readlines(credential_path, chomp: true).each do |line|
        next if line.empty? || line.start_with?("#")

        key, value = line.split("=", 2)
        next unless key && value && credential_env_keys.include?(key)

        cleaned = Emcp.sanitize_env_value(value)
        if cleaned.empty?
          ENV.delete(key)
        else
          ENV[key] = cleaned
        end
      end
    end

    sanitize_credential_env!
  end

  def persist_credentials!(values)
    current = credential_hash
    values.each do |key, value|
      key = key.to_s
      next unless credential_env_keys.include?(key)

      cleaned = Emcp.sanitize_env_value(value)
      if cleaned.empty?
        current.delete(key)
        ENV.delete(key)
      else
        current[key] = cleaned
        ENV[key] = cleaned
      end
    end

    self.credentials_hash = current
    save! if persisted?

    if current.empty?
      File.delete(credential_path) if File.file?(credential_path)
    else
      File.write(
        credential_path,
        current.map { |key, value| "#{key}=#{value}" }.join("\n") + "\n",
        perm: 0o600,
      )
    end
    invalidate_auth_status!
  end

  def clear_oauth_token_file!
    File.delete(oauth_token_path) if File.file?(oauth_token_path)
    self.oauth_token_hash = nil
    save! if persisted?
  end

  def persist_oauth_token_payload!(payload)
    raise "OAuth token payload must be a JSON object" unless payload.is_a?(Hash)

    self.oauth_token_hash = payload
    save! if persisted?
    FileUtils.mkdir_p(File.dirname(oauth_token_path))
    File.write(oauth_token_path, JSON.pretty_generate(payload) + "\n", perm: 0o600)
  end

  def oauth_result_body(result)
    raise "Empty OAuth token response" if result.nil?

    body = result.is_a?(Hash) ? (result[:body] || result["body"] || result) : nil
    raise "OAuth token response body is missing" unless body.is_a?(Hash)

    status = result[:status] || result["status"]
    if status && !status.to_i.between?(200, 299)
      raise "OAuth token exchange failed with status #{status}"
    end

    stringify_keys(body)
  end

  def parse_token_json_paste(token_json)
    raw = token_json.to_s.strip
    return nil if raw.empty?

    parsed = JSON.parse(raw)
    raise "token_json must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError => e
    raise "invalid token_json: #{e.message}"
  end

  def store_oauth_token_payload!(payload, rejection_message:)
    body = stringify_keys(payload)
    access_token = Emcp.sanitize_env_value(body["access_token"])
    raise "OAuth response did not include an access_token" if access_token.empty?
    raise "oauth_access_env is not configured" if oauth_access_env.to_s.empty?

    persist_oauth_token_payload!(body)
    updates = { oauth_access_env => access_token }
    updates[oauth_refresh_env] = Emcp.sanitize_env_value(body["refresh_token"]) if oauth_refresh_env
    persist_credentials!(updates)
    replace_client!
    raise rejection_message unless auth_status(force: true)[:authenticated]

    schedule_service_token_refresh_job!
    true
  end

  def persist_refreshed_oauth_token!(access_token:, refresh_token:, body:)
    persist_oauth_token_payload!(body) if body.is_a?(Hash)
    updates = { oauth_access_env => access_token }
    updates[oauth_refresh_env] = refresh_token if oauth_refresh_env
    persist_credentials!(updates)
  end

  def apply_credentials_probe!(updates, rejection_message:)
    old = credential_env_keys.to_h { |key| [key, ENV[key]] }
    persist_credentials!(updates)
    replace_client!
    status = auth_status(force: true)
    if status[:authenticated]
      schedule_service_token_refresh_job!
      return true
    end

    persist_credentials!(old)
    replace_client!
    detail = status[:error].to_s.strip
    raise(detail.empty? ? rejection_message : "#{rejection_message}: #{detail}")
  end

  def credential_env_keys = []
  def oauth_access_env = nil
  def oauth_refresh_env = nil
  def replace_client!; end

  private

  def credential_hash
    credentials_hash.transform_keys(&:to_s)
  end

  def sanitize_credential_env!
    credential_env_keys.each do |key|
      next unless ENV.key?(key)

      cleaned = Emcp.sanitize_env_value(ENV[key])
      if cleaned.empty?
        ENV.delete(key)
      else
        ENV[key] = cleaned
      end
    end
  end
end
