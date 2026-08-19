# frozen_string_literal: true

require "openssl"
require "tmpdir"

ENV["EMCP_PUBLIC_URL"] ||= "http://localhost:8765"
ENV["EMCP_AUTH_TOKEN"] ||= "static-test-token"
ENV["EMCP_SECRET_KEY"] ||= "test-secret-key"
ENV["EMCP_AUTH_USERS_PATH"] ||= File.join(Dir.tmpdir, "emcp-auth-users-#{Process.pid}")
ENV["EMCP_ALLOWED_HOSTS"] ||= "localhost,127.0.0.1"
ENV["EMCP_ALLOW_WRITE"] ||= "false"
ENV["EMCP_REQUEST_LOG"] ||= File.join(Dir.tmpdir, "emcp-test-requests-#{Process.pid}.logs")

users_path = ENV.fetch("EMCP_AUTH_USERS_PATH")
unless File.file?(users_path)
  digest = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("EMCP_SECRET_KEY"), "secret")
  File.write(users_path, "user1:#{digest} # test\n")
end

def with_env(overrides)
  previous = {}
  overrides.each do |key, value|
    key = key.to_s
    previous[key] = ENV.key?(key) ? ENV[key] : :__unset__
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value.to_s
    end
  end
  yield
ensure
  previous.each do |key, value|
    if value == :__unset__
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
