# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "securerandom"
require_relative "twitter_client"

module Madcp
  module Servers
    module Twitter
      class Server < Integration
        server_id "twitter"
        display_name "Twitter / X"
        description "Users, posts, timelines, search, likes, follows, and bookmarks through the X API v2."
        version "0.1.0"
        oauth_token_retrieval true

        DEFAULT_SCOPES = [
          "tweet.read",
          "tweet.write",
          "users.read",
          "follows.read",
          "follows.write",
          "like.read",
          "like.write",
          "list.read",
          "bookmark.read",
          "bookmark.write",
          "offline.access",
        ].join(" ").freeze

        DEFAULT_TWEET_FIELDS = "created_at,public_metrics,lang,conversation_id,in_reply_to_user_id,referenced_tweets"
        DEFAULT_USER_FIELDS = "created_at,description,public_metrics,verified,profile_image_url"

        def initialize(config:)
          super
          @client = build_client
        end

        def instructions
          "Use Twitter/X tools to inspect and manage posts and social graph data via API v2. " \
            "User-context OAuth 2.0 is required for write tools. " \
            "Write tools remain disabled unless TWITTER_ALLOW_WRITE=true. " \
            "API access depends on your X developer tier."
        end

        def auth_help_content
          {
            title: "Authorize Twitter / X",
            description: "Use the OAuth 2.0 flow in this form (authorization code + PKCE), " \
                         "the same MadCP token-retrieval harness as Fatture in Cloud.",
            steps: [
              "Create an app in the X Developer Portal and enable OAuth 2.0.",
              "Set TWITTER_CLIENT_ID and TWITTER_CLIENT_SECRET (confidential client).",
              "Register the callback URL shown below as an allowed redirect URI.",
              "Choose Retrieve OAuth token, then confirm the token was saved on the callback page.",
            ],
            commands: [],
            note: "MadCP stores the full OAuth token response under data/twitter/oauth_token.json. " \
                  "X API access and rate limits depend on your developer tier.",
          }
        end

        def auth_fields
          [
            {
              name: "twitter_token",
              label: "Twitter / X access token",
              type: "password",
              required: false,
              help: "Paste a user access token, or use Retrieve OAuth token below.",
              env: "TWITTER_TOKEN",
            },
          ]
        end

        def auth_status_cache_ttl = 120

        def fetch_auth_status
          load_credentials!
          result = @client.get("/users/me", query: { "user.fields" => DEFAULT_USER_FIELDS }, raise_on_error: false)
          body = result[:body].is_a?(Hash) ? result[:body] : {}
          data = body["data"].is_a?(Hash) ? body["data"] : {}
          ok = result[:status].between?(200, 299)
          status = {
            authenticated: ok,
            username: data["username"],
            name: data["name"],
            id: data["id"],
          }
          status[:error] = "Twitter API #{result[:status]}: #{body}" unless ok
          status
        rescue StandardError => e
          { authenticated: false, error: e.message }
        end

        def apply_credentials(params)
          token = Madcp.sanitize_env_value(params["twitter_token"])
          old = credential_env_keys.to_h { |key| [key, ENV[key]] }
          persist_credentials!("TWITTER_TOKEN" => token)
          @client = build_client
          return true if auth_status(force: true)[:authenticated]

          persist_credentials!(old)
          @client = build_client
          raise "Twitter token was rejected"
        ensure
          token = nil
        end

        def apply_oauth_result!(result)
          body = oauth_result_body(result)
          access_token = Madcp.sanitize_env_value(body["access_token"] || body[:access_token])
          raise "OAuth response did not include an access_token" if access_token.empty?

          persist_oauth_token_payload!(body)
          persist_credentials!(
            "TWITTER_TOKEN" => access_token,
            "TWITTER_REFRESH_TOKEN" => Madcp.sanitize_env_value(
              body["refresh_token"] || body[:refresh_token],
            ),
          )
          @client = build_client
          raise "Twitter token was rejected" unless auth_status(force: true)[:authenticated]

          true
        end

        def apply_oauth_token_paste!(access_token:, token_json: nil)
          token = Madcp.sanitize_env_value(access_token)
          raise "Access token is required" if token.empty?

          payload = parse_token_json_paste(token_json)
          payload = payload.merge("access_token" => token) if payload
          payload ||= { "access_token" => token }

          persist_oauth_token_payload!(payload)
          persist_credentials!(
            "TWITTER_TOKEN" => token,
            "TWITTER_REFRESH_TOKEN" => Madcp.sanitize_env_value(
              payload["refresh_token"] || payload[:refresh_token],
            ),
          )
          @client = build_client
          raise "Twitter token was rejected" unless auth_status(force: true)[:authenticated]

          true
        end

        def clear_credentials!
          File.delete(oauth_token_path) if File.file?(oauth_token_path)
          persist_credentials!(
            "TWITTER_TOKEN" => nil,
            "TWITTER_REFRESH_TOKEN" => nil,
          )
          @client = build_client
        end

        def oauth_call(callback_url:, state:)
          client_id = Madcp.sanitize_env_value(ENV["TWITTER_CLIENT_ID"])
          raise "TWITTER_CLIENT_ID is required" if client_id.empty?

          code_verifier = pkce_verifier
          code_challenge = pkce_challenge(code_verifier)
          query = {
            response_type: "code",
            client_id: client_id,
            redirect_uri: callback_url,
            scope: ENV.fetch("TWITTER_OAUTH_SCOPES", DEFAULT_SCOPES),
            state: state,
            code_challenge: code_challenge,
            code_challenge_method: "S256",
          }
          {
            authorization_url: "https://twitter.com/i/oauth2/authorize?#{URI.encode_www_form(query)}",
            code_verifier: code_verifier,
          }
        end

        def oauth_exchange(callback_url:, params:, state_data: nil)
          code_verifier = state_data.is_a?(Hash) ? state_data[:code_verifier] || state_data["code_verifier"] : nil
          raise "OAuth PKCE code_verifier missing from state" if code_verifier.to_s.empty?
          raise "OAuth callback did not include a code" if params["code"].to_s.empty?

          @client.exchange_code(
            callback_url: callback_url,
            code: params["code"],
            code_verifier: code_verifier,
          )
        end

        def configure_tools
          define_user_tools
          define_tweet_read_tools
          define_timeline_tools
          define_write_tools
        end

        protected

        def credential_env_keys
          %w[
            TWITTER_TOKEN
            TWITTER_REFRESH_TOKEN
          ]
        end

        private

        def build_client
          Client.new(on_token_refresh: method(:persist_refreshed_token!))
        end

        def persist_refreshed_token!(access_token:, refresh_token:, body:)
          persist_oauth_token_payload!(body) if body.is_a?(Hash)
          persist_credentials!(
            "TWITTER_TOKEN" => access_token,
            "TWITTER_REFRESH_TOKEN" => refresh_token,
          )
        end

        def oauth_token_path
          File.join(data_dir, "oauth_token.json")
        end

        def oauth_result_body(result)
          raise "Empty OAuth token response" if result.nil?

          body = result.is_a?(Hash) ? (result[:body] || result["body"] || result) : nil
          raise "OAuth token response body is missing" unless body.is_a?(Hash)

          status = result[:status] || result["status"]
          if status && !status.to_i.between?(200, 299)
            raise "OAuth token exchange failed with status #{status}"
          end

          body.transform_keys(&:to_s)
        end

        def persist_oauth_token_payload!(payload)
          raise "OAuth token payload must be a JSON object" unless payload.is_a?(Hash)

          FileUtils.mkdir_p(File.dirname(oauth_token_path))
          File.write(oauth_token_path, JSON.pretty_generate(payload) + "\n", perm: 0o600)
        end

        def parse_token_json_paste(token_json)
          raw = token_json.to_s.strip
          return nil if raw.empty?

          parsed = JSON.parse(raw)
          raise "token_json must be a JSON object" unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError => e
          raise "invalid token_json: #{e.message}"
        end

        def pkce_verifier
          SecureRandom.urlsafe_base64(64).delete("=")
        end

        def pkce_challenge(verifier)
          Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        end

        def define_user_tools
          define_tool(
            name: "twitter_me",
            description: "Return the authenticated X user.",
            properties: {
              user_fields: string_prop("Comma-separated user.fields"),
            },
          ) do |user_fields: nil|
            api_get(
              "/users/me",
              query: compact_hash("user.fields" => user_fields || DEFAULT_USER_FIELDS),
            )
          end

          define_tool(
            name: "twitter_user_lookup",
            description: "Lookup users by username or ID.",
            properties: {
              usernames: string_prop("Comma-separated usernames"),
              ids: string_prop("Comma-separated user IDs"),
              user_fields: string_prop("Comma-separated user.fields"),
            },
          ) do |usernames: nil, ids: nil, user_fields: nil|
            raise "usernames or ids is required" if usernames.to_s.strip.empty? && ids.to_s.strip.empty?

            if !usernames.to_s.strip.empty?
              api_get(
                "/users/by",
                query: compact_hash(
                  usernames: usernames,
                  "user.fields" => user_fields || DEFAULT_USER_FIELDS,
                ),
              )
            else
              api_get(
                "/users",
                query: compact_hash(
                  ids: ids,
                  "user.fields" => user_fields || DEFAULT_USER_FIELDS,
                ),
              )
            end
          end

          define_tool(
            name: "twitter_followers",
            description: "List followers of a user.",
            properties: {
              user_id: string_prop("User ID; defaults to authenticated user"),
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              user_fields: string_prop("Comma-separated user.fields"),
            },
          ) do |user_id: nil, max_results: nil, pagination_token: nil, user_fields: nil|
            uid = user_id_value(user_id)
            api_get(
              "/users/#{uid}/followers",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "user.fields" => user_fields || DEFAULT_USER_FIELDS,
              ),
            )
          end

          define_tool(
            name: "twitter_following",
            description: "List accounts a user follows.",
            properties: {
              user_id: string_prop("User ID; defaults to authenticated user"),
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              user_fields: string_prop("Comma-separated user.fields"),
            },
          ) do |user_id: nil, max_results: nil, pagination_token: nil, user_fields: nil|
            uid = user_id_value(user_id)
            api_get(
              "/users/#{uid}/following",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "user.fields" => user_fields || DEFAULT_USER_FIELDS,
              ),
            )
          end
        end

        def define_tweet_read_tools
          define_tool(
            name: "twitter_tweets_lookup",
            description: "Lookup tweets by ID.",
            properties: {
              ids: string_prop("Comma-separated tweet IDs"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
              expansions: string_prop("Comma-separated expansions"),
              user_fields: string_prop("Comma-separated user.fields"),
            },
            required: ["ids"],
          ) do |ids:, tweet_fields: nil, expansions: nil, user_fields: nil|
            api_get(
              "/tweets",
              query: compact_hash(
                ids: ids,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
                expansions: expansions,
                "user.fields" => user_fields,
              ),
            )
          end

          define_tool(
            name: "twitter_user_tweets",
            description: "List recent tweets posted by a user.",
            properties: {
              user_id: string_prop("User ID; defaults to authenticated user"),
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              exclude: string_prop("Comma-separated exclusions such as retweets,replies"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
              since_id: string_prop("Return results with ID greater than since_id"),
              until_id: string_prop("Return results with ID less than until_id"),
            },
          ) do |user_id: nil, max_results: nil, pagination_token: nil, exclude: nil, tweet_fields: nil, since_id: nil, until_id: nil|
            uid = user_id_value(user_id)
            api_get(
              "/users/#{uid}/tweets",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                exclude: exclude,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
                since_id: since_id,
                until_id: until_id,
              ),
            )
          end

          define_tool(
            name: "twitter_search_recent",
            description: "Search recent tweets (last 7 days).",
            properties: {
              query: string_prop("Search query"),
              max_results: integer_prop("Page size"),
              next_token: string_prop("Pagination token"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
              expansions: string_prop("Comma-separated expansions"),
              sort_order: string_prop("recency or relevancy"),
            },
            required: ["query"],
          ) do |query:, max_results: nil, next_token: nil, tweet_fields: nil, expansions: nil, sort_order: nil|
            api_get(
              "/tweets/search/recent",
              query: compact_hash(
                query: query,
                max_results: max_results,
                next_token: next_token,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
                expansions: expansions,
                sort_order: sort_order,
              ),
            )
          end

          define_tool(
            name: "twitter_liked_tweets",
            description: "List tweets liked by a user.",
            properties: {
              user_id: string_prop("User ID; defaults to authenticated user"),
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
            },
          ) do |user_id: nil, max_results: nil, pagination_token: nil, tweet_fields: nil|
            uid = user_id_value(user_id)
            api_get(
              "/users/#{uid}/liked_tweets",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
              ),
            )
          end

          define_tool(
            name: "twitter_list_tweets",
            description: "List tweets from a list.",
            properties: {
              list_id: string_prop("List ID"),
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
            },
            required: ["list_id"],
          ) do |list_id:, max_results: nil, pagination_token: nil, tweet_fields: nil|
            api_get(
              "/lists/#{path_id(list_id, "list_id")}/tweets",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
              ),
            )
          end

          define_tool(
            name: "twitter_bookmarks",
            description: "List bookmarked tweets for the authenticated user.",
            properties: {
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
            },
          ) do |max_results: nil, pagination_token: nil, tweet_fields: nil|
            uid = user_id_value(nil)
            api_get(
              "/users/#{uid}/bookmarks",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
              ),
            )
          end
        end

        def define_timeline_tools
          define_tool(
            name: "twitter_home_timeline",
            description: "Get the reverse-chronological home timeline for the authenticated user.",
            properties: {
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
              exclude: string_prop("Comma-separated exclusions such as retweets,replies"),
            },
          ) do |max_results: nil, pagination_token: nil, tweet_fields: nil, exclude: nil|
            uid = user_id_value(nil)
            api_get(
              "/users/#{uid}/timelines/reverse_chronological",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
                exclude: exclude,
              ),
            )
          end

          define_tool(
            name: "twitter_mentions",
            description: "List mentions of a user.",
            properties: {
              user_id: string_prop("User ID; defaults to authenticated user"),
              max_results: integer_prop("Page size"),
              pagination_token: string_prop("Pagination token"),
              tweet_fields: string_prop("Comma-separated tweet.fields"),
            },
          ) do |user_id: nil, max_results: nil, pagination_token: nil, tweet_fields: nil|
            uid = user_id_value(user_id)
            api_get(
              "/users/#{uid}/mentions",
              query: compact_hash(
                max_results: max_results,
                pagination_token: pagination_token,
                "tweet.fields" => tweet_fields || DEFAULT_TWEET_FIELDS,
              ),
            )
          end
        end

        def define_write_tools
          define_tool(
            name: "twitter_tweet_create",
            description: "Create a tweet. Provide text and/or a raw JSON payload " \
                         "(use reply.in_reply_to_tweet_id for replies).",
            properties: {
              text: string_prop("Tweet text"),
              payload: object_prop("Optional raw JSON body merged over text"),
            },
            write: true,
          ) do |text: nil, payload: {}|
            body = stringify_keys(payload.is_a?(Hash) ? payload : {})
            body["text"] = text unless text.to_s.strip.empty?
            raise "text or payload.text is required" if body["text"].to_s.strip.empty?

            api_post("/tweets", body: body)
          end

          define_tool(
            name: "twitter_tweet_delete",
            description: "Delete a tweet by ID.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:|
            api_delete("/tweets/#{path_id(tweet_id, "tweet_id")}")
          end

          define_tool(
            name: "twitter_like",
            description: "Like a tweet.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
              user_id: string_prop("User ID; defaults to authenticated user"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_post("/users/#{uid}/likes", body: { tweet_id: path_id(tweet_id, "tweet_id") })
          end

          define_tool(
            name: "twitter_unlike",
            description: "Unlike a tweet.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
              user_id: string_prop("User ID; defaults to authenticated user"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_delete("/users/#{uid}/likes/#{path_id(tweet_id, "tweet_id")}")
          end

          define_tool(
            name: "twitter_retweet",
            description: "Retweet a tweet.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
              user_id: string_prop("User ID; defaults to authenticated user"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_post("/users/#{uid}/retweets", body: { tweet_id: path_id(tweet_id, "tweet_id") })
          end

          define_tool(
            name: "twitter_unretweet",
            description: "Undo a retweet.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
              user_id: string_prop("User ID; defaults to authenticated user"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_delete("/users/#{uid}/retweets/#{path_id(tweet_id, "tweet_id")}")
          end

          define_tool(
            name: "twitter_follow",
            description: "Follow a user.",
            properties: {
              target_user_id: string_prop("User ID to follow"),
              user_id: string_prop("Acting user ID; defaults to authenticated user"),
            },
            required: ["target_user_id"],
            write: true,
          ) do |target_user_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_post(
              "/users/#{uid}/following",
              body: { target_user_id: path_id(target_user_id, "target_user_id") },
            )
          end

          define_tool(
            name: "twitter_unfollow",
            description: "Unfollow a user.",
            properties: {
              target_user_id: string_prop("User ID to unfollow"),
              user_id: string_prop("Acting user ID; defaults to authenticated user"),
            },
            required: ["target_user_id"],
            write: true,
          ) do |target_user_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_delete("/users/#{uid}/following/#{path_id(target_user_id, "target_user_id")}")
          end

          define_tool(
            name: "twitter_bookmark_create",
            description: "Bookmark a tweet.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
              user_id: string_prop("User ID; defaults to authenticated user"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_post("/users/#{uid}/bookmarks", body: { tweet_id: path_id(tweet_id, "tweet_id") })
          end

          define_tool(
            name: "twitter_bookmark_delete",
            description: "Remove a bookmark.",
            properties: {
              tweet_id: string_prop("Tweet ID"),
              user_id: string_prop("User ID; defaults to authenticated user"),
            },
            required: ["tweet_id"],
            write: true,
          ) do |tweet_id:, user_id: nil|
            uid = user_id_value(user_id)
            api_delete("/users/#{uid}/bookmarks/#{path_id(tweet_id, "tweet_id")}")
          end
        end

        def user_id_value(value = nil)
          id = value.to_s.strip
          return path_id(id, "user_id") unless id.empty?

          me = @client.get("/users/me")
          data = me[:body].is_a?(Hash) ? me[:body]["data"] : nil
          uid = data.is_a?(Hash) ? data["id"].to_s : ""
          raise "could not resolve authenticated user id" if uid.empty?

          uid
        end

        def path_id(value, label)
          id = value.to_s.strip
          raise "#{label} is required" if id.empty?
          raise "invalid #{label}" unless id.match?(/\A[0-9]+\z/)

          id
        end

        def object_prop(description)
          { type: "object", description: description, additionalProperties: true }
        end

        def compact_hash(values)
          values.reject { |_, value| value.nil? || value == "" }
        end

        def stringify_keys(values)
          values.to_h.transform_keys(&:to_s)
        end

        def api_get(path, query: {})
          api_response { @client.get(path, query: query) }
        end

        def api_post(path, body:)
          api_response { @client.post(path, body: body) }
        end

        def api_delete(path)
          api_response { @client.delete(path) }
        end

        def api_response
          text_response(JSON.pretty_generate(yield))
        rescue Client::Error => e
          text_response("ERROR: #{e.message}")
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::Twitter::Server)
