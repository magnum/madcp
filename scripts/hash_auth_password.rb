#!/usr/bin/env ruby
# frozen_string_literal: true

# Hash a password for data/auth_users:
#   MADCP_SECRET_KEY=... ruby scripts/hash_auth_password.rb 'my-password'
#   ruby scripts/hash_auth_password.rb user1 'my-password'   # prints a full line

require "openssl"

secret = ENV["MADCP_SECRET_KEY"].to_s.strip
secret = ENV["SECRET_KEY"].to_s.strip if secret.empty?
abort "Set MADCP_SECRET_KEY (or SECRET_KEY)" if secret.empty?

username = nil
password =
  if ARGV.length >= 2
    username = ARGV[0]
    ARGV[1]
  elsif ARGV.length == 1
    ARGV[0]
  else
    abort "Usage: #{$PROGRAM_NAME} [username] password"
  end

digest = OpenSSL::HMAC.hexdigest("SHA256", secret, password)
if username
  puts "#{username}:#{digest} # #{username}"
else
  puts digest
end
