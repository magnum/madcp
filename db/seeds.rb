# frozen_string_literal: true

password = ENV.fetch("MADCP_USER1_PASSWORD") do
  if Rails.env.local?
    "madcp-dev-password"
  else
    raise "Set MADCP_USER1_PASSWORD before seeding"
  end
end

ENV["API_KEY_HMAC_SECRET_KEY"] ||= "dev-api-key-hmac-secret" if Rails.env.local?

user = User.find_or_initialize_by(email: "user1@madcp.local")
user.firstname = "User"
user.lastname = "One"
user.password = password
user.password_confirmation = password
user.save!
user.add_role(:admin) unless user.admin?

user.create_default_plan if PlanType.exists?(code: "basic") && user.plans.none?

McpServer.discover!

if Rails.env.local? && user.api_keys.none?
  raw = user.api_key!
  puts "Created development ApiKey for user1: #{raw}"
end

puts "Seeded user1@madcp.local (admin). Password from MADCP_USER1_PASSWORD (dev default: madcp-dev-password)."
