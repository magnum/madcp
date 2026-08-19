# frozen_string_literal: true

# Pull production SQLite DBs from the Kamal host (SSH + scp of storage/*.sqlite3)
# and overwrite local development databases.
#
# Optional (env):
#   REMOTE_DB_SSH               overrides SSH target; default root@<first web host> from config/deploy.yml
#   REMOTE_STORAGE_PATH         default: host path from deploy volumes (/data/emcp/storage)
#   DB_SYNC_PRIMARY_ONLY=1      sync only primary (default: primary + cache + queue + cable)
#
# You must type yes (any case) when prompted: local databases are always overwritten interactively (no bypass).
#
# Usage:
#   bin/rails db:remote_pull
#   DB_SYNC_PRIMARY_ONLY=1 bin/rails db:remote_pull
#   REMOTE_DB_SSH=deploy@example.com bin/rails db:remote_pull

require "shellwords"
require "fileutils"
require "yaml"

module DbRemoteSync
  module_function

  def load_deploy_yaml
    path = Rails.root.join("config/deploy.yml")
    return nil unless path.exist?

    if YAML.respond_to?(:safe_load_file)
      YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true)
    else
      YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true)
    end
  end

  def remote_db_ssh_default_from_deploy
    yaml = load_deploy_yaml
    return nil unless yaml

    hosts = yaml.dig("servers", "web")
    host = Array(hosts).first
    return nil unless host.present?

    "root@#{host.to_s.strip}"
  end

  def remote_storage_path_default_from_deploy
    yaml = load_deploy_yaml
    return nil unless yaml

    volumes = Array(yaml["volumes"])
    volume = volumes.find { |v| v.to_s.include?(":/rails/storage") }
    return nil unless volume

    volume.to_s.split(":", 2).first
  end
end

namespace :db do
  desc "Copy remote SQLite DBs (via SSH) into local storage (development only)"
  task remote_pull: :environment do
    if Rails.env.production?
      abort "Refusing to run in production. Use development (or another non-prod env)."
    end

    ssh_target = ENV["REMOTE_DB_SSH"].presence ||
      DbRemoteSync.remote_db_ssh_default_from_deploy ||
      abort("Set REMOTE_DB_SSH or define servers.web in config/deploy.yml")
    storage_path = ENV["REMOTE_STORAGE_PATH"].presence ||
      DbRemoteSync.remote_storage_path_default_from_deploy ||
      "/data/emcp/storage"
    primary_only = ENV["DB_SYNC_PRIMARY_ONLY"].present?

    roles = primary_only ? %w[primary] : %w[primary cache queue cable]

    pairs = roles.filter_map do |name|
      prod = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: name)
      dev = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: name)
      next unless prod && dev

      [name, prod, dev]
    end

    if pairs.empty?
      abort "No database config pairs found. Check config/database.yml production / #{Rails.env}."
    end

    ssh_source = ENV["REMOTE_DB_SSH"].present? ? "env" : "config/deploy.yml"
    storage_source = ENV["REMOTE_STORAGE_PATH"].present? ? "env" : "config/deploy.yml"

    puts <<~WARN

      Remote pull will use:
        REMOTE_DB_SSH         #{ssh_target}  (#{ssh_source})
        REMOTE_STORAGE_PATH   #{storage_path}  (#{storage_source})

      This will OVERWRITE local #{Rails.env} database(s):
      #{pairs.map { |_, _, d| "  - #{d.database}" }.join("\n")}

      Type yes to continue:
    WARN
    abort "Aborted." unless $stdin.gets.to_s.strip.casecmp?("yes")

    pairs.each do |role, prod, dev|
      remote_db = File.join(storage_path, File.basename(prod.database))
      local_db = Rails.root.join(dev.database)

      FileUtils.mkdir_p(File.dirname(local_db))

      puts "\n==> [#{role}] scp #{ssh_target}:#{remote_db} -> #{local_db}"

      unless system("scp", "#{ssh_target}:#{remote_db}", local_db.to_s)
        abort "scp failed for #{role} (#{remote_db})"
      end

      puts "    #{File.size(local_db)} bytes — done."
    end

    puts "\n==> Remote pull complete."
  end
end
