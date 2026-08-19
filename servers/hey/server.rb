# frozen_string_literal: true

require "cgi"
require_relative "hey_client"

module Emcp
  module Servers
    module Hey
      class Server < ::McpServer
        server_id "hey"
        display_name "HEY"
        description "Email, calendar, todos, habits, time tracking, and journal via the official HEY CLI."
        version "0.1.0"

        LIMIT_PROPERTIES = {
          limit: { type: "integer", description: "Maximum number of items" },
          fetch_all: { type: "boolean", description: "Fetch all pages instead of applying limit" },
        }.freeze
        HEY_BULLET_LINE = /\A[[:blank:]]*[-–—*•][[:blank:]]+(.+?)\z/
        HEY_NUMBERED_LINE = /\A[[:blank:]]*\d+[.)][[:blank:]]+(.+?)\z/
        HEY_PARAGRAPH_SPACER = "<div><br></div>"

        def instructions
          "Use HEY tools to read and manage email and personal productivity data. " \
            "Call hey_skill before complex workflows. " \
            "For hey_compose / hey_reply prefer the paragraphs array (one idea per item, " \
            "blank line between ideas). EmCP converts bodies to HTML with real paragraph " \
            "spacing; lines starting with -, –, *, • or 1. become bullet/numbered lists. " \
            "Write tools are disabled unless allow_write_methods is enabled."
        end

        def auth_help_content
          {
            title: "Get a HEY token",
            description: "Authenticate the HEY CLI on a trusted computer, then paste the token below.",
            steps: [
              "Sign in with the HEY CLI.",
              "Print the token without extra formatting.",
            ],
            commands: [
              { label: "Sign in", value: "hey auth login" },
              { label: "Copy the token", value: "hey auth token --quiet" },
            ],
            note: "Treat the token as a password and paste it only over HTTPS.",
          }
        end

        def auth_fields
          [{
            name: "hey_token",
            label: "HEY token",
            type: "password",
            required: false,
            help: "Paste the output of: hey auth token --quiet",
            value: -> { current_hey_token },
          }]
        end

        def fetch_auth_status
          raw = @client.run(@client.auth_status, truncate: false)
          data = JSON.parse(raw)
          data = data["data"] || data
          { authenticated: data["authenticated"] == true, source: data["source"] }
        rescue StandardError => e
          { authenticated: false, error: e.message }
        end

        def apply_credentials(params)
          token = params["hey_token"].to_s.strip
          @client.run(@client.auth_login(token), truncate: false) unless token.empty?
          invalidate_auth_status!
          raise "HEY CLI is not authenticated" unless auth_status(force: true)[:authenticated]

          true
        ensure
          token = nil
        end

        def clear_credentials!
          @client.run(@client.auth_logout, truncate: false)
          invalidate_auth_status!
        rescue CliError
          invalidate_auth_status!
          nil
        end

        def configure_tools
          define_skill
          define_read_tools
          define_write_tools
        end

        def replace_client!
          @client = Client.new
        end

        def credential_env_keys = []

        # HEY/Action Text renders content as HTML: plain newlines collapse to spaces.
        # Convert MCP plain text / paragraphs into Trix-friendly HTML with paragraph gaps
        # and real ul/ol lists (adjacent bare <div>s do not create blank lines in HEY).
        def format_hey_email_body(message: nil, paragraphs: nil)
          parts = hey_email_paragraphs(message: message, paragraphs: paragraphs)
          return "" if parts.empty?

          joined = parts.join("\n\n")
          return joined if hey_html_body?(joined)

          hey_plain_parts_to_html(parts)
        end

        private

        def hey_email_paragraphs(message: nil, paragraphs: nil)
          if paragraphs.is_a?(Array) && !paragraphs.empty?
            return paragraphs.map { |part| normalize_hey_newlines(part.to_s).strip }.reject(&:empty?)
          end

          text = normalize_hey_newlines(message.to_s).strip
          return [] if text.empty?
          return [text] if hey_html_body?(text)

          chunks = text.split(/\n[[:blank:]]*\n+/).map(&:strip).reject(&:empty?)
          chunks.empty? ? [text] : chunks
        end

        def hey_plain_parts_to_html(parts)
          hey_coalesce_list_parts(parts).map { |part| hey_render_block(part) }.join(HEY_PARAGRAPH_SPACER)
        end

        # Adjacent paragraphs that are only list items become one list (no blank between bullets).
        def hey_coalesce_list_parts(parts)
          parts.each_with_object([]) do |part, coalesced|
            if coalesced.any? &&
               (kind = hey_list_only_kind(coalesced.last)) &&
               kind == hey_list_only_kind(part)
              coalesced[-1] = "#{coalesced.last}\n#{part}"
            else
              coalesced << part
            end
          end
        end

        def hey_list_only_kind(block)
          lines = block.to_s.split("\n").map(&:rstrip).reject(&:empty?)
          return nil if lines.empty?

          kinds = lines.map { |line| hey_list_item(line)&.first }
          return nil unless kinds.all? && kinds.uniq.size == 1

          kinds.first
        end

        def hey_render_block(block)
          lines = block.to_s.split("\n").map(&:rstrip)
          html = +""
          text_lines = []
          list_kind = nil
          list_items = []

          flush_text = lambda do
            next if text_lines.empty?

            html << "<div>#{hey_escape_with_breaks(text_lines.join("\n"))}</div>"
            text_lines = []
          end

          flush_list = lambda do
            next if list_items.empty?

            tag = list_kind == :ol ? "ol" : "ul"
            items = list_items.map { |item| "<li>#{CGI.escapeHTML(item)}</li>" }.join
            html << "<#{tag}>#{items}</#{tag}>"
            list_items = []
            list_kind = nil
          end

          lines.each do |line|
            kind, content = hey_list_item(line)
            if kind
              flush_text.call
              if list_kind && list_kind != kind
                flush_list.call
              end
              list_kind = kind
              list_items << content
            else
              flush_list.call
              text_lines << line
            end
          end
          flush_text.call
          flush_list.call
          html
        end

        def hey_list_item(line)
          if (match = line.match(HEY_BULLET_LINE))
            [:ul, match[1].strip]
          elsif (match = line.match(HEY_NUMBERED_LINE))
            [:ol, match[1].strip]
          end
        end

        def normalize_hey_newlines(text)
          cleaned = text.to_s.gsub("\r\n", "\n").gsub("\r", "\n")
          # Models sometimes send the two-character sequence \n instead of a real newline.
          cleaned = cleaned.gsub("\\n", "\n") if !cleaned.include?("\n") && cleaned.include?("\\n")
          cleaned
        end

        def hey_html_body?(text)
          text.match?(/\A\s*</)
        end

        def hey_escape_with_breaks(text)
          CGI.escapeHTML(text.to_s).gsub("\n", "<br>")
        end

        def current_hey_token
          return "" unless auth_status[:authenticated]

          @client.run(@client.auth_token, truncate: false).to_s.strip
        rescue StandardError
          ""
        end

        def define_skill
          path = File.join(__dir__, "skills", "hey", "SKILL.md")
          define_resource(
            uri: "hey://skill",
            name: "hey_skill",
            description: "Official HEY CLI agent skill.",
            mime_type: "text/markdown",
          ) { File.read(path) }
          define_tool(
            name: "hey_skill",
            description: "Return the official HEY CLI workflows, ID rules, and command reference.",
          ) { text_response(File.read(path)) }
        end

        def define_read_tools
          define_tool(name: "hey_auth_status", description: "Show HEY CLI authentication status.") do
            cli_response(@client, @client.auth_status)
          end

          define_tool(
            name: "hey_auth_token",
            description: "Print the HEY CLI access token. Sensitive; use only when explicitly needed.",
          ) { cli_response(@client, @client.auth_token) }

          define_tool(name: "hey_config_show", description: "Show HEY CLI configuration.") do
            cli_response(@client, @client.config_show)
          end

          define_tool(
            name: "hey_boxes",
            description: "List HEY inbox boxes.",
            properties: LIMIT_PROPERTIES,
          ) { |limit: nil, fetch_all: false| cli_response(@client, @client.boxes(limit: limit, fetch_all: fetch_all)) }

          define_tool(
            name: "hey_box",
            description: "List messages in a HEY box.",
            properties: { box: string_prop("Box name or ID"), **LIMIT_PROPERTIES },
            required: ["box"],
          ) { |box:, limit: nil, fetch_all: false| cli_response(@client, @client.box(box, limit: limit, fetch_all: fetch_all)) }

          define_tool(
            name: "hey_search",
            description: "Search messages in a HEY box by text, date, or unread state.",
            properties: {
              query: string_prop("Text matched against subject, sender, contacts, and summary"),
              box: string_prop("Box name or ID; defaults to imbox"),
              limit: integer_prop("Maximum results; defaults to 20"),
              offset: integer_prop("Number of matching results to skip"),
              after: string_prop("Only messages on/after YYYY-MM-DD"),
              before: string_prop("Only messages on/before YYYY-MM-DD"),
              unseen_only: boolean_prop("Only unread messages"),
              deep: boolean_prop("Scan the complete box"),
            },
          ) do |query: nil, box: "imbox", limit: 20, offset: 0, after: nil, before: nil,
                   unseen_only: false, deep: false|
            hey_search(
              query: query, box: box, limit: limit, offset: offset,
              after: after, before: before, unseen_only: unseen_only, deep: deep,
            )
          end

          define_tool(
            name: "hey_threads",
            description: "Read a HEY email thread.",
            properties: { topic_id: string_prop("Topic ID"), html: boolean_prop("Include HTML bodies") },
            required: ["topic_id"],
          ) { |topic_id:, html: false| cli_response(@client, @client.threads(topic_id, html: html)) }

          define_tool(
            name: "hey_drafts",
            description: "List HEY drafts.",
            properties: LIMIT_PROPERTIES,
          ) { |limit: nil, fetch_all: false| cli_response(@client, @client.drafts(limit: limit, fetch_all: fetch_all)) }

          define_tool(name: "hey_calendars", description: "List HEY calendars.") do
            cli_response(@client, @client.calendars)
          end

          define_tool(
            name: "hey_recordings",
            description: "List HEY calendar recordings.",
            properties: {
              calendar_id: string_prop("Calendar ID"),
              starts_on: string_prop("Start date YYYY-MM-DD"),
              ends_on: string_prop("End date YYYY-MM-DD"),
              **LIMIT_PROPERTIES,
            },
            required: ["calendar_id"],
          ) do |calendar_id:, starts_on: nil, ends_on: nil, limit: nil, fetch_all: false|
            cli_response(
              @client,
              @client.recordings(
                calendar_id,
                starts_on: starts_on,
                ends_on: ends_on,
                limit: limit,
                fetch_all: fetch_all,
              ),
            )
          end

          define_tool(
            name: "hey_todo_list",
            description: "List HEY todos.",
            properties: LIMIT_PROPERTIES,
          ) { |limit: nil, fetch_all: false| cli_response(@client, @client.todos(limit: limit, fetch_all: fetch_all)) }

          define_tool(
            name: "hey_timetrack_current",
            description: "Show the current HEY time tracking entry.",
          ) { cli_response(@client, @client.timetrack("current")) }

          define_tool(
            name: "hey_timetrack_list",
            description: "List HEY time tracking entries.",
            properties: LIMIT_PROPERTIES,
          ) do |limit: nil, fetch_all: false|
            cli_response(@client, @client.timetrack_list(limit: limit, fetch_all: fetch_all))
          end

          define_tool(
            name: "hey_journal_list",
            description: "List HEY journal entries.",
            properties: LIMIT_PROPERTIES,
          ) { |limit: nil, fetch_all: false| cli_response(@client, @client.journal_list(limit: limit, fetch_all: fetch_all)) }

          define_tool(
            name: "hey_journal_read",
            description: "Read a HEY journal entry.",
            properties: {
              date: string_prop("Date YYYY-MM-DD; defaults to today"),
              html: boolean_prop("Include HTML"),
            },
          ) { |date: nil, html: false| cli_response(@client, @client.journal_read(date: date, html: html)) }

          define_tool(name: "hey_doctor", description: "Run HEY CLI diagnostics.") do
            cli_response(@client, @client.doctor)
          end
        end

        def hey_search(query:, box:, limit:, offset:, after:, before:, unseen_only:, deep:)
          if query.to_s.strip.empty? && after.to_s.empty? && before.to_s.empty? && !unseen_only
            return text_response("ERROR: provide query, after, before, or unseen_only")
          end

          raw = @client.run(
            @client.box(box.to_s.empty? ? "imbox" : box, limit: deep ? nil : 500, fetch_all: deep),
            truncate: false,
          )
          envelope = JSON.parse(raw)
          postings = Array((envelope["data"] || envelope)["postings"])
          needle = query.to_s.downcase.strip
          postings.select! do |posting|
            date = posting["created_at"].to_s[0, 10]
            haystack = [
              posting["name"], posting["summary"], posting["alternative_sender_name"],
              posting.dig("creator", "name"),
              *Array(posting["contacts"]).flat_map { |contact| [contact["name"], contact["email_address"]] },
            ].compact.join("\n").downcase
            (needle.empty? || haystack.include?(needle)) &&
              (!unseen_only || !posting["seen"]) &&
              (after.to_s.empty? || date >= after) &&
              (before.to_s.empty? || date <= before)
          end
          page = postings.drop([offset.to_i, 0].max).first(limit.to_i.clamp(1, 500))
          rows = page.map do |posting|
            {
              id: posting["id"],
              topic_id: posting["topic_id"] || posting["app_url"].to_s[%r{/topics/(\d+)}, 1],
              subject: posting["name"],
              from: posting.dig("creator", "name") || posting["alternative_sender_name"],
              date: posting["created_at"],
              seen: posting["seen"],
              summary: posting["summary"].to_s[0, 160],
            }
          end
          text_response(JSON.generate(count: rows.length, matched: postings.length, postings: rows))
        rescue CliError, JSON::ParserError => e
          text_response("ERROR: #{e.message}")
        end

        def define_write_tools
          define_tool(
            name: "hey_compose",
            description: "Compose and send an email. Prefer paragraphs (array) so line breaks are preserved in HEY.",
            properties: {
              subject: string_prop("Email subject"),
              paragraphs: array_prop(
                "Preferred email body: one paragraph/list item/signature per element. " \
                "Joined with blank lines and converted to HTML for HEY.",
              ),
              message: string_prop(
                "Email body as a single string (use real newlines or \\n between paragraphs). " \
                "Prefer paragraphs when the email has more than one short sentence.",
              ),
              to: string_prop("Comma-separated recipients"),
              cc: string_prop("Comma-separated CC recipients"),
              bcc: string_prop("Comma-separated BCC recipients"),
              thread_id: string_prop("Optional thread ID"),
            },
            required: ["subject"],
            write: true,
          ) do |subject:, paragraphs: nil, message: nil, to: nil, cc: nil, bcc: nil, thread_id: nil|
            body = format_hey_email_body(message: message, paragraphs: paragraphs)
            raise "message or paragraphs is required" if body.empty?

            cli_response(
              @client,
              @client.compose(
                subject: subject,
                message: body,
                to: to,
                cc: cc,
                bcc: bcc,
                thread_id: thread_id,
              ),
            )
          end

          define_tool(
            name: "hey_reply",
            description: "Reply to a HEY thread. Prefer paragraphs (array) so line breaks are preserved in HEY.",
            properties: {
              topic_id: string_prop("Topic ID"),
              paragraphs: array_prop(
                "Preferred reply body: one paragraph/list item/signature per element.",
              ),
              message: string_prop("Reply body as a single string; prefer paragraphs for multi-paragraph replies"),
            },
            required: ["topic_id"],
            write: true,
          ) do |topic_id:, paragraphs: nil, message: nil|
            body = format_hey_email_body(message: message, paragraphs: paragraphs)
            raise "message or paragraphs is required" if body.empty?

            cli_response(@client, @client.reply(topic_id, body))
          end

          %w[seen unseen].each do |action|
            define_tool(
              name: "hey_#{action}",
              description: "Mark HEY postings as #{action}.",
              properties: { posting_ids: array_prop("Posting IDs") },
              required: ["posting_ids"],
              write: true,
            ) { |posting_ids:| cli_response(@client, @client.public_send(action, posting_ids)) }
          end

          define_tool(
            name: "hey_todo_add",
            description: "Create a HEY todo.",
            properties: { title: string_prop("Todo title"), date: string_prop("Date YYYY-MM-DD") },
            required: ["title"],
            write: true,
          ) { |title:, date: nil| cli_response(@client, @client.todo_add(title, date: date)) }

          {
            "complete" => :todo_complete,
            "uncomplete" => :todo_uncomplete,
            "delete" => :todo_delete,
          }.each do |action, method|
            define_tool(
              name: "hey_todo_#{action}",
              description: "#{action.capitalize} a HEY todo.",
              properties: { todo_id: string_prop("Todo ID") },
              required: ["todo_id"],
              write: true,
            ) { |todo_id:| cli_response(@client, @client.public_send(method, todo_id)) }
          end

          %w[complete uncomplete].each do |action|
            define_tool(
              name: "hey_habit_#{action}",
              description: "#{action.capitalize} a HEY habit occurrence.",
              properties: { habit_id: string_prop("Habit ID"), date: string_prop("Date YYYY-MM-DD") },
              required: ["habit_id"],
              write: true,
            ) do |habit_id:, date: nil|
              cli_response(@client, @client.public_send("habit_#{action}", habit_id, date: date))
            end
          end

          %w[start stop].each do |action|
            define_tool(
              name: "hey_timetrack_#{action}",
              description: "#{action.capitalize} HEY time tracking.",
              write: true,
            ) { cli_response(@client, @client.timetrack(action)) }
          end

          define_tool(
            name: "hey_journal_write",
            description: "Create or update a HEY journal entry.",
            properties: { content: string_prop("Journal content"), date: string_prop("Date YYYY-MM-DD") },
            required: ["content"],
            write: true,
          ) { |content:, date: nil| cli_response(@client, @client.journal_write(content, date: date)) }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Hey::Server)
