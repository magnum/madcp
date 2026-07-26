# frozen_string_literal: true

module Madcp
  module Servers
    module Hey
      class Client < CliClient
        def initialize
          super(
            bin: ENV.fetch("HEY_BIN", "hey"),
            timeout: ENV.fetch("HEY_TIMEOUT", "30").to_i,
            max_chars: ENV.fetch("HEY_MAX_CHARS", "12000").to_i,
          )
        end

        def json(*parts) = [*parts, "--json"]

        def limited(args, limit: nil, fetch_all: false)
          if fetch_all
            args << "--all"
          elsif limit
            args.push("--limit", limit.to_i.clamp(1, 500).to_s)
          end
          args
        end

        def boxes(limit: nil, fetch_all: false) = limited(json("boxes"), limit: limit, fetch_all: fetch_all)
        def box(name, limit: nil, fetch_all: false) = limited(json("box", name), limit: limit, fetch_all: fetch_all)
        def threads(topic_id, html: false) = json("threads", topic_id).tap { |a| a << "--html" if html }
        def drafts(limit: nil, fetch_all: false) = limited(json("drafts"), limit: limit, fetch_all: fetch_all)

        def compose(subject:, message:, to: nil, cc: nil, bcc: nil, thread_id: nil)
          ["compose", "--subject", subject, "-m", message].tap do |args|
            args.push("--to", to) if to
            args.push("--cc", cc) if cc
            args.push("--bcc", bcc) if bcc
            args.push("--thread-id", thread_id) if thread_id
            args << "--json"
          end
        end

        def reply(topic_id, message) = ["reply", topic_id, "-m", message, "--json"]
        def seen(ids) = ["seen", *ids, "--json"]
        def unseen(ids) = ["unseen", *ids, "--json"]
        def calendars = json("calendars")

        def recordings(calendar_id, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false)
          limited(json("recordings", calendar_id).tap do |args|
            args.push("--starts-on", starts_on) if starts_on
            args.push("--ends-on", ends_on) if ends_on
          end, limit: limit, fetch_all: fetch_all)
        end

        def todos(limit: nil, fetch_all: false) = limited(json("todo", "list"), limit: limit, fetch_all: fetch_all)
        def todo_add(title, date: nil)
          ["todo", "add", title].tap { |args| args.push("--date", date) if date }.push("--json")
        end
        def todo_complete(id) = json("todo", "complete", id)
        def todo_uncomplete(id) = json("todo", "uncomplete", id)
        def todo_delete(id) = json("todo", "delete", id)
        def habit_complete(id, date: nil) = dated("habit", "complete", id, date: date)
        def habit_uncomplete(id, date: nil) = dated("habit", "uncomplete", id, date: date)
        def timetrack(action) = json("timetrack", action)
        def timetrack_list(limit: nil, fetch_all: false) = limited(json("timetrack", "list"), limit: limit, fetch_all: fetch_all)
        def journal_list(limit: nil, fetch_all: false) = limited(json("journal", "list"), limit: limit, fetch_all: fetch_all)
        def journal_read(date: nil, html: false) = json("journal", "read", *[date].compact).tap { |a| a << "--html" if html }
        def journal_write(content, date: nil) = ["journal", "write", *[date].compact, "-c", content, "--json"]
        def auth_status = json("auth", "status")
        def auth_token = ["auth", "token", "--quiet"]
        def auth_login(token) = ["auth", "login", "--token", token, "--json"]
        def auth_logout = json("auth", "logout")
        def doctor = json("doctor")
        def config_show = json("config", "show")

        private

        def dated(*parts, date:)
          [*parts].tap { |args| args.push("--date", date) if date }.push("--json")
        end
      end
    end
  end
end
