# frozen_string_literal: true

require_relative "bluesky_client"

module Madcp
  module Servers
    module Bluesky
      class Server < Integration
        server_id "bluesky"
        display_name "Bluesky"
        description "Profiles, feeds, posts, search, follows, likes, and notifications through the Bluesky AT Protocol API."
        version "0.1.0"

        def initialize(config:)
          super
          @client = build_client
        end

        def instructions
          "Use Bluesky tools to read and write AT Protocol social data. " \
            "Actor arguments accept a handle (example.bsky.social) or DID. " \
            "Write tools remain disabled unless BLUESKY_ALLOW_WRITE=true."
        end

        def auth_help_content
          {
            title: "Authorize Bluesky",
            description: "MadCP uses a Bluesky app password with com.atproto.server.createSession " \
                         "(legacy app-password flow; ATProto OAuth with PAR/DPoP is not used here).",
            steps: [
              "Open Bluesky Settings → App Passwords and create a password for MadCP.",
              "Paste your handle (or email) and the app password into this form.",
              "Optional: set BLUESKY_PDS_HOST if your account is not on bsky.social.",
            ],
            commands: [
              {
                label: "Create a session against the configured PDS",
                value: 'curl -X POST "$BLUESKY_PDS_HOST/xrpc/com.atproto.server.createSession" ' \
                       '-H "Content-Type: application/json" ' \
                       '-d "{\"identifier\":\"$BLUESKY_HANDLE\",\"password\":\"$BLUESKY_APP_PASSWORD\"}"',
              },
            ],
            note: "Treat the app password like a password and paste it only over HTTPS. " \
                  "Access/refresh JWTs are stored under data/bluesky/credentials.env and redacted from tool output.",
          }
        end

        def auth_fields
          [
            {
              name: "bluesky_handle",
              label: "Bluesky handle or email",
              type: "text",
              required: false,
              help: "Account handle (example.bsky.social) or login email.",
              env: "BLUESKY_HANDLE",
            },
            {
              name: "bluesky_app_password",
              label: "App password",
              type: "password",
              required: false,
              help: "App password from Bluesky Settings (not your account password).",
              env: "BLUESKY_APP_PASSWORD",
            },
            {
              name: "bluesky_pds_host",
              label: "PDS host (optional)",
              type: "text",
              required: false,
              help: "Defaults to https://bsky.social.",
              env: "BLUESKY_PDS_HOST",
            },
          ]
        end

        def auth_status_cache_ttl = 300

        def fetch_auth_status
          load_credentials!
          @client.ensure_session!
          result = @client.get("com.atproto.server.getSession", raise_on_error: false)
          body = result[:body].is_a?(Hash) ? result[:body] : {}
          ok = result[:status].between?(200, 299)
          status = {
            authenticated: ok,
            handle: body["handle"] || ENV["BLUESKY_HANDLE"],
            did: body["did"] || ENV["BLUESKY_DID"],
          }
          status[:error] = "Bluesky API #{result[:status]}: #{body}" unless ok
          status
        rescue StandardError => e
          {
            authenticated: false,
            handle: Madcp.sanitize_env_value(ENV["BLUESKY_HANDLE"]),
            did: Madcp.sanitize_env_value(ENV["BLUESKY_DID"]),
            error: e.message,
          }
        end

        def apply_credentials(params)
          handle = params["bluesky_handle"].to_s.strip
          password = params["bluesky_app_password"].to_s.strip
          pds_host = params["bluesky_pds_host"].to_s.strip
          apply_credentials_probe!(
            {
              "BLUESKY_HANDLE" => handle,
              "BLUESKY_APP_PASSWORD" => password,
              "BLUESKY_PDS_HOST" => pds_host,
              "BLUESKY_ACCESS_JWT" => nil,
              "BLUESKY_REFRESH_JWT" => nil,
              "BLUESKY_DID" => nil,
            },
            rejection_message: "Bluesky credentials were rejected",
          )
        ensure
          password = nil
        end

        def clear_credentials!
          persist_credentials!(
            "BLUESKY_HANDLE" => nil,
            "BLUESKY_APP_PASSWORD" => nil,
            "BLUESKY_PDS_HOST" => nil,
            "BLUESKY_ACCESS_JWT" => nil,
            "BLUESKY_REFRESH_JWT" => nil,
            "BLUESKY_DID" => nil,
          )
          replace_client!
        end

        def configure_tools
          define_profile_tools
          define_feed_tools
          define_graph_tools
          define_write_tools
        end

        protected

        def credential_env_keys
          %w[
            BLUESKY_HANDLE
            BLUESKY_APP_PASSWORD
            BLUESKY_PDS_HOST
            BLUESKY_ACCESS_JWT
            BLUESKY_REFRESH_JWT
            BLUESKY_DID
          ]
        end

        def replace_client!
          @client = build_client
        end

        private

        def build_client
          Client.new(on_session: method(:persist_session!))
        end

        def persist_session!(access_jwt:, refresh_jwt:, did:, handle:)
          updates = {
            "BLUESKY_ACCESS_JWT" => access_jwt,
            "BLUESKY_REFRESH_JWT" => refresh_jwt,
            "BLUESKY_DID" => did,
          }
          updates["BLUESKY_HANDLE"] = handle unless handle.to_s.strip.empty?
          persist_credentials!(updates)
        end

        def define_profile_tools
          define_tool(
            name: "bluesky_me",
            description: "Return the authenticated Bluesky session and profile.",
          ) do
            session = @client.get("com.atproto.server.getSession")
            did = ENV["BLUESKY_DID"].to_s
            did = session.dig(:body, "did").to_s if did.empty?
            profile =
              if did.empty?
                nil
              else
                @client.get("app.bsky.actor.getProfile", query: { actor: did })
              end
            text_response(
              JSON.pretty_generate(
                {
                  session: session,
                  profile: profile,
                },
              ),
            )
          rescue Client::Error => e
            text_response("ERROR: #{e.message}")
          end

          define_tool(
            name: "bluesky_get_profile",
            description: "Get one actor profile by handle or DID.",
            properties: {
              actor: string_prop("Handle or DID"),
            },
            required: ["actor"],
          ) do |actor:|
            api_get("app.bsky.actor.getProfile", query: { actor: actor })
          end

          define_tool(
            name: "bluesky_get_profiles",
            description: "Get multiple actor profiles.",
            properties: {
              actors: array_prop("Handles or DIDs"),
            },
            required: ["actors"],
          ) do |actors:|
            raise "actors must be a non-empty array" unless actors.is_a?(Array) && !actors.empty?

            api_get("app.bsky.actor.getProfiles", query: { actors: actors })
          end

          define_tool(
            name: "bluesky_search_actors",
            description: "Search actors by typeahead query.",
            properties: {
              q: string_prop("Search query"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
            },
            required: ["q"],
          ) do |q:, limit: nil, cursor: nil|
            api_get(
              "app.bsky.actor.searchActors",
              query: compact_hash(q: q, limit: limit, cursor: cursor),
            )
          end

          define_tool(
            name: "bluesky_get_actor_feeds",
            description: "List custom feeds created by an actor.",
            properties: {
              actor: string_prop("Handle or DID; defaults to authenticated DID"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
            },
          ) do |actor: nil, limit: nil, cursor: nil|
            api_get(
              "app.bsky.feed.getActorFeeds",
              query: compact_hash(actor: actor_value(actor), limit: limit, cursor: cursor),
            )
          end
        end

        def define_feed_tools
          define_tool(
            name: "bluesky_get_timeline",
            description: "Get the authenticated user's home timeline.",
            properties: {
              algorithm: string_prop("Optional feed algorithm"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
            },
          ) do |algorithm: nil, limit: nil, cursor: nil|
            api_get(
              "app.bsky.feed.getTimeline",
              query: compact_hash(algorithm: algorithm, limit: limit, cursor: cursor),
            )
          end

          define_tool(
            name: "bluesky_get_author_feed",
            description: "Get posts authored by an actor.",
            properties: {
              actor: string_prop("Handle or DID"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
              filter: string_prop("Optional filter such as posts_no_replies"),
            },
            required: ["actor"],
          ) do |actor:, limit: nil, cursor: nil, filter: nil|
            api_get(
              "app.bsky.feed.getAuthorFeed",
              query: compact_hash(actor: actor, limit: limit, cursor: cursor, filter: filter),
            )
          end

          define_tool(
            name: "bluesky_get_post_thread",
            description: "Get a post thread by AT URI.",
            properties: {
              uri: string_prop("AT URI of the post"),
              depth: integer_prop("Reply depth"),
              parentHeight: integer_prop("Parent height"),
            },
            required: ["uri"],
          ) do |uri:, depth: nil, parentHeight: nil|
            api_get(
              "app.bsky.feed.getPostThread",
              query: compact_hash(uri: uri, depth: depth, parentHeight: parentHeight),
            )
          end

          define_tool(
            name: "bluesky_get_posts",
            description: "Hydrate posts by AT URI list.",
            properties: {
              uris: array_prop("AT URIs"),
            },
            required: ["uris"],
          ) do |uris:|
            raise "uris must be a non-empty array" unless uris.is_a?(Array) && !uris.empty?

            api_get("app.bsky.feed.getPosts", query: { uris: uris })
          end

          define_tool(
            name: "bluesky_search_posts",
            description: "Search posts.",
            properties: {
              q: string_prop("Search query"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
              sort: string_prop("Sort order, for example latest or top"),
              author: string_prop("Optional author handle/DID filter"),
              since: string_prop("Optional since timestamp"),
              until_time: string_prop("Optional until timestamp"),
            },
            required: ["q"],
          ) do |q:, limit: nil, cursor: nil, sort: nil, author: nil, since: nil, until_time: nil|
            api_get(
              "app.bsky.feed.searchPosts",
              query: compact_hash(
                q: q,
                limit: limit,
                cursor: cursor,
                sort: sort,
                author: author,
                since: since,
                until: until_time,
              ),
            )
          end

          define_tool(
            name: "bluesky_get_likes",
            description: "List likes for a post.",
            properties: {
              uri: string_prop("AT URI of the post"),
              cid: string_prop("Optional post CID"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
            },
            required: ["uri"],
          ) do |uri:, cid: nil, limit: nil, cursor: nil|
            api_get(
              "app.bsky.feed.getLikes",
              query: compact_hash(uri: uri, cid: cid, limit: limit, cursor: cursor),
            )
          end

          define_tool(
            name: "bluesky_list_notifications",
            description: "List notifications for the authenticated user.",
            properties: {
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
              seenAt: string_prop("Optional seenAt filter timestamp"),
            },
          ) do |limit: nil, cursor: nil, seenAt: nil|
            api_get(
              "app.bsky.notification.listNotifications",
              query: compact_hash(limit: limit, cursor: cursor, seenAt: seenAt),
            )
          end
        end

        def define_graph_tools
          define_tool(
            name: "bluesky_get_followers",
            description: "List followers of an actor.",
            properties: {
              actor: string_prop("Handle or DID"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
            },
            required: ["actor"],
          ) do |actor:, limit: nil, cursor: nil|
            api_get(
              "app.bsky.graph.getFollowers",
              query: compact_hash(actor: actor, limit: limit, cursor: cursor),
            )
          end

          define_tool(
            name: "bluesky_get_follows",
            description: "List accounts an actor follows.",
            properties: {
              actor: string_prop("Handle or DID"),
              limit: integer_prop("Max results"),
              cursor: string_prop("Pagination cursor"),
            },
            required: ["actor"],
          ) do |actor:, limit: nil, cursor: nil|
            api_get(
              "app.bsky.graph.getFollows",
              query: compact_hash(actor: actor, limit: limit, cursor: cursor),
            )
          end
        end

        def define_write_tools
          define_tool(
            name: "bluesky_create_post",
            description: "Create a post. Provide text and optional reply/langs, or a raw record payload.",
            properties: {
              text: string_prop("Post text"),
              created_at: string_prop("RFC3339 createdAt; defaults to now UTC"),
              langs: array_prop("Optional language codes"),
              reply: object_prop("Optional reply object with root/parent {uri,cid}"),
              record: object_prop("Optional full app.bsky.feed.post record (overrides text helpers)"),
            },
            write: true,
          ) do |text: nil, created_at: nil, langs: nil, reply: nil, record: nil|
            post_record =
              if record.is_a?(Hash) && !record.empty?
                stringify_keys(record)
              else
                raise "text is required when record is omitted" if text.to_s.strip.empty?

                compact_hash(
                  "$type" => "app.bsky.feed.post",
                  "text" => text,
                  "createdAt" => created_at || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
                  "langs" => langs,
                  "reply" => reply,
                )
              end
            post_record["$type"] ||= "app.bsky.feed.post"
            post_record["createdAt"] ||= Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
            api_post(
              "com.atproto.repo.createRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.feed.post",
                record: post_record,
              },
            )
          end

          define_tool(
            name: "bluesky_delete_post",
            description: "Delete a post by AT URI or rkey.",
            properties: {
              uri: string_prop("AT URI of the post"),
              rkey: string_prop("Record key when uri is omitted"),
            },
            write: true,
          ) do |uri: nil, rkey: nil|
            key = rkey_from(uri: uri, rkey: rkey, collection: "app.bsky.feed.post")
            api_post(
              "com.atproto.repo.deleteRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.feed.post",
                rkey: key,
              },
            )
          end

          define_tool(
            name: "bluesky_like",
            description: "Like a post.",
            properties: {
              uri: string_prop("AT URI of the post"),
              cid: string_prop("CID of the post"),
            },
            required: %w[uri cid],
            write: true,
          ) do |uri:, cid:|
            api_post(
              "com.atproto.repo.createRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.feed.like",
                record: {
                  "$type" => "app.bsky.feed.like",
                  "subject" => { "uri" => uri, "cid" => cid },
                  "createdAt" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
                },
              },
            )
          end

          define_tool(
            name: "bluesky_unlike",
            description: "Delete a like record by AT URI or rkey.",
            properties: {
              uri: string_prop("AT URI of the like record"),
              rkey: string_prop("Like record key when uri is omitted"),
            },
            write: true,
          ) do |uri: nil, rkey: nil|
            key = rkey_from(uri: uri, rkey: rkey, collection: "app.bsky.feed.like")
            api_post(
              "com.atproto.repo.deleteRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.feed.like",
                rkey: key,
              },
            )
          end

          define_tool(
            name: "bluesky_repost",
            description: "Repost a post.",
            properties: {
              uri: string_prop("AT URI of the post"),
              cid: string_prop("CID of the post"),
            },
            required: %w[uri cid],
            write: true,
          ) do |uri:, cid:|
            api_post(
              "com.atproto.repo.createRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.feed.repost",
                record: {
                  "$type" => "app.bsky.feed.repost",
                  "subject" => { "uri" => uri, "cid" => cid },
                  "createdAt" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
                },
              },
            )
          end

          define_tool(
            name: "bluesky_follow",
            description: "Follow an actor by DID.",
            properties: {
              subject: string_prop("DID of the actor to follow"),
            },
            required: ["subject"],
            write: true,
          ) do |subject:|
            api_post(
              "com.atproto.repo.createRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.graph.follow",
                record: {
                  "$type" => "app.bsky.graph.follow",
                  "subject" => subject,
                  "createdAt" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
                },
              },
            )
          end

          define_tool(
            name: "bluesky_unfollow",
            description: "Delete a follow record by AT URI or rkey.",
            properties: {
              uri: string_prop("AT URI of the follow record"),
              rkey: string_prop("Follow record key when uri is omitted"),
            },
            write: true,
          ) do |uri: nil, rkey: nil|
            key = rkey_from(uri: uri, rkey: rkey, collection: "app.bsky.graph.follow")
            api_post(
              "com.atproto.repo.deleteRecord",
              body: {
                repo: require_did,
                collection: "app.bsky.graph.follow",
                rkey: key,
              },
            )
          end

          define_tool(
            name: "bluesky_update_seen_notifications",
            description: "Mark notifications as seen.",
            properties: {
              seenAt: string_prop("RFC3339 timestamp; defaults to now UTC"),
            },
            write: true,
          ) do |seenAt: nil|
            api_post(
              "app.bsky.notification.updateSeen",
              body: {
                seenAt: seenAt || Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"),
              },
            )
          end
        end

        def actor_value(value = nil)
          actor = value.to_s.strip
          actor = ENV["BLUESKY_DID"].to_s.strip if actor.empty?
          actor = ENV["BLUESKY_HANDLE"].to_s.strip if actor.empty?
          raise "actor is required" if actor.empty?

          actor
        end

        def require_did
          did = ENV["BLUESKY_DID"].to_s.strip
          if did.empty?
            @client.ensure_session!
            did = ENV["BLUESKY_DID"].to_s.strip
          end
          raise "authenticated DID is required" if did.empty?

          did
        end

        def rkey_from(uri:, rkey:, collection:)
          key = rkey.to_s.strip
          return key unless key.empty?

          at_uri = uri.to_s.strip
          raise "uri or rkey is required" if at_uri.empty?
          raise "invalid AT URI" unless at_uri.start_with?("at://")

          parts = at_uri.split("/")
          raise "AT URI does not match #{collection}" unless parts[-2] == collection

          parts.last.to_s
        end

        def api_get(nsid, query: {})
          api_response { @client.get(nsid, query: query) }
        end

        def api_post(nsid, body:)
          api_response { @client.post(nsid, body: body) }
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::Bluesky::Server)
