#!/usr/bin/env ruby
# frozen_string_literal: true

# Hash a password for data/auth_users:
#   MADCP_SECRET_KEY=... ruby scripts/hash_auth_password.rb 'my-password'
#   ruby scripts/hash_auth_password.rb user1 'my-password'

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "madcp/app_auth"

secret = ENV.fetch("MADCP_SECRET_KEY") { ENV.fetch("SECRET_KEY", "") }.to_s.strip
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

digest = Madcp::AppAuth.hash_password(password, secret: secret)
if username
  puts "#{username}:#{digest} # #{username}"
else
  puts digest
end
