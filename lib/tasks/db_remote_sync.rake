# frozen_string_literal: true

# Pull production DB from Kamal host (SSH + docker exec pg_dump) and restore into local PostgreSQL.
#
# pg_dump runs inside the Postgres container; local connections typically use trust in the
# official image, so no password is required for the dump step.
#
# Optional (env):
#   REMOTE_DB_SSH               overrides SSH target; default root@<accessories.db.host> from config/deploy.yml
#   REMOTE_PG_CONTAINER         default: POSTGRES_HOST from config/deploy.yml (env.clear), else <service>-db, else madcp-db
#   REMOTE_PG_USER              default: postgres (set madcp if you use POSTGRES_USER: madcp)
#   REMOTE_POSTGRES_PASSWORD    only if pg_hba inside the container requires a password for local connections
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

    host = yaml.dig("accessories", "db", "host")
    return nil unless host.present?

    "root@#{host.to_s.strip}"
  end

  def remote_pg_container_default_from_deploy
    yaml = load_deploy_yaml
    return nil unless yaml

    pg_host = yaml.dig("env", "clear", "POSTGRES_HOST")
    return pg_host.to_s.strip if pg_host.present?

    service = yaml["service"]
    "#{service}-db" if service.present?
  end
end

namespace :db do
  desc "Dump remote PostgreSQL (via SSH + docker) and pg_restore into local DB (development only)"
  task remote_pull: :environment do
    if Rails.env.production?
      abort "Refusing to run in production. Use development (or another non-prod env)."
    end

    ssh_target = ENV["REMOTE_DB_SSH"].presence ||
      DbRemoteSync.remote_db_ssh_default_from_deploy ||
      abort("Set REMOTE_DB_SSH or define accessories.db.host in config/deploy.yml")
    container_from_deploy = DbRemoteSync.remote_pg_container_default_from_deploy.presence
    container = ENV["REMOTE_PG_CONTAINER"].presence ||
      container_from_deploy ||
      "madcp-db"
    pg_user = ENV.fetch("REMOTE_PG_USER", "postgres")
    optional_pg_password = ENV["REMOTE_POSTGRES_PASSWORD"].presence
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
    container_source = if ENV["REMOTE_PG_CONTAINER"].present?
      "env"
    elsif container_from_deploy
      "config/deploy.yml"
    else
      "default"
    end

    puts <<~WARN

      Remote pull will use:
        REMOTE_DB_SSH         #{ssh_target}  (#{ssh_source})
        REMOTE_PG_CONTAINER   #{container}  (#{container_source})
        REMOTE_PG_USER        #{pg_user}

      This will OVERWRITE local #{Rails.env} database(s):
      #{pairs.map { |_, _, d| "  - #{d.database}" }.join("\n")}

      Type yes to continue:
    WARN
    abort "Aborted." unless $stdin.gets.to_s.strip.casecmp?("yes")

    dump_dir = Rails.root.join("tmp", "db_remote_sync")
    FileUtils.mkdir_p(dump_dir)
    timestamp = Time.zone.now.strftime("%Y%m%d_%H%M%S")

    pairs.each do |role, prod, dev|
      prod_db = prod.database
      dev_db = dev.database
      dump_path = dump_dir.join("#{role}_#{timestamp}.dump")

      puts "\n==> [#{role}] pg_dump #{prod_db} from #{ssh_target} -> #{dump_path}"

      exec_prefix = ["docker", "exec", "-i"]
      exec_prefix += ["-e", "PGPASSWORD=#{optional_pg_password}"] if optional_pg_password
      remote_cmd = Shellwords.shelljoin(
        exec_prefix + [
          container,
          "pg_dump",
          "-U", pg_user,
          "-d", prod_db,
          "--no-owner",
          "--no-acl",
          "-F", "c"
        ]
      )

      status = nil
      File.open(dump_path, "wb") do |f|
        IO.popen(["ssh", ssh_target, remote_cmd], "rb") do |io|
          IO.copy_stream(io, f)
        end
        status = $?
      end
      unless status&.success?
        FileUtils.rm_f(dump_path)
        abort "pg_dump failed (#{role}), ssh exit #{status&.exitstatus.inspect}"
      end

      if !File.exist?(dump_path) || File.size(dump_path).zero?
        abort "Dump file missing or empty: #{dump_path}"
      end

      puts "    #{File.size(dump_path)} bytes"

      puts "==> [#{role}] pg_restore -> #{dev_db} (local)"

      terminate_sql = <<~SQL.squish
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = '#{dev_db.gsub("'", "''")}' AND pid <> pg_backend_pid();
      SQL
      system("psql", "-d", "postgres", "-c", terminate_sql, out: File::NULL, err: File::NULL)

      drop_sql = %(DROP DATABASE IF EXISTS "#{dev_db.gsub('"', '""')}";)
      system("psql", "-d", "postgres", "-c", drop_sql) || abort("Failed to DROP DATABASE #{dev_db}")

      create_sql = %(CREATE DATABASE "#{dev_db.gsub('"', '""')}";)
      system("psql", "-d", "postgres", "-c", create_sql) || abort("Failed to CREATE DATABASE #{dev_db}")

      unless system("pg_restore", "--no-owner", "--no-acl", "-d", dev_db, dump_path.to_s)
        abort "pg_restore failed for #{dev_db}"
      end

      puts "    done."
    end

    puts "\n==> Remote pull complete. Run bin/rails db:migrate if schema differs from production."
  end
end
