ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# Production (Kamal): load shared app env from the persistent storage volume.
# Does not override variables already set by Kamal (RAILS_MASTER_KEY, APP_HOST, …).
# Host path: /data/emcp/storage/.env  →  container: /rails/storage/.env
begin
  require "dotenv"
  storage_env = File.expand_path("../storage/.env", __dir__)
  Dotenv.load(storage_env) if File.file?(storage_env)
rescue LoadError
  # dotenv not bundled (e.g. incomplete install) — skip
end
