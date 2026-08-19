# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "securerandom"
require_relative "twitter_client"

module Emcp
  module Servers
    module Twitter
      class Server < ::McpServer
        server_id "twitter"
        display_name "Twitter / X"
        description "Users, posts, timelines, search, likes, follows, and bookmarks through the X API v2."
        version "0.1.0"
        oauth_token_retrieval true

        def self.default_service_token_refresh_in_minutes = 90

        DEFAULT_READ_SCOPES = [
          "tweet.read",
          "users.read",
          "follows.read",
          "like.read",
          "list.read",
          "bookmark.read",
          "offline.access",
        ].freeze

        DEFAULT_WRITE_SCOPES = [
          "tweet.write",
          "follows.write",
          "like.write",
          "bookmark.write",
        ].freeze

        # Broad default used only when TWITTER_ALLOW_WRITE=true and TWITTER_OAUTH_SCOPES is unset.
        DEFAULT_SCOPES = (DEFAULT_READ_SCOPES + DEFAULT_WRITE_SCOPES).join(" ").freeze

        DEFAULT_TWEET_FIELDS = "created_at,public_metrics,lang,conversation_id,in_reply_to_user_id,referenced_tweets"
        DEFAULT_USER_FIELDS = "created_at,description,public_metrics,verified,profile_image_url"
        after_initialize :ensure_runtime_client
        after_find :ensure_runtime_client

        def ensure_runtime_client
          return if defined?(@client) && @client
          replace_client! if respond_to?(:replace_client!, true)
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
                         "the same EmCP token-retrieval harness as Fatture in Cloud.",
            steps: [
              "In the X Developer Portal, open your app → User authentication settings.",
              "Enable OAuth 2.0, App type = Web App / Automated App or Bot (confidential client).",
              "App permissions: Read for EmCP’s default scopes; Read and write only if you need writes " \
                "(TWITTER_ALLOW_WRITE=true) or custom write scopes.",
              "Callback URI / Redirect URL must be EXACTLY the URL shown below (copy-paste).",
              "Also set Website URL (e.g. your EmCP public URL) — X often rejects auth without it.",
              "Paste the OAuth 2.0 Client ID and Client Secret below (not the old API Key / Consumer Key).",
              "Choose Retrieve OAuth token — values from the fields above are used (and saved) for the flow.",
              "Optionally paste a token manually and Save credentials, or confirm the token after the OAuth callback.",
            ],
            commands: [],
            note: "error=invalid_scope means portal App permissions do not cover the scopes EmCP requests " \
                  "(see below). “Something went wrong” on X is usually the same mismatch, or a wrong callback URI. " \
                  "EmCP stores tokens under data/twitter/oauth_token.json.",
          }
        end

        def auth_fields
          [
            {
              name: "twitter_client_id",
              label: "OAuth 2.0 Client ID",
              type: "text",
              required: true,
              oauth_app: true,
              help: "From X Developer Portal → Keys and tokens → OAuth 2.0 Client ID. Form values override empty ENV.",
              env: "TWITTER_CLIENT_ID",
            },
            {
              name: "twitter_client_secret",
              label: "OAuth 2.0 Client Secret",
              type: "password",
              required: true,
              oauth_app: true,
              help: "From X Developer Portal → Keys and tokens → OAuth 2.0 Client Secret. Leave blank to keep a saved secret.",
              env: "TWITTER_CLIENT_SECRET",
            },
            {
              name: "twitter_token",
              label: "Twitter / X access token",
              type: "password",
              required: false,
              help: "Filled by Retrieve OAuth token, or paste a user access token and Save credentials.",
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

        def prepare_provider_oauth!(params)
          persist_oauth_app_credentials!(params)
          load_credentials!
          replace_client!
        end

        def apply_credentials(params)
          load_credentials!
          updates = oauth_app_credential_updates(params)
          token = Emcp.sanitize_env_value(params["twitter_token"])

          effective_id = updates["TWITTER_CLIENT_ID"].presence ||
            Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_ID"])
          effective_secret = updates["TWITTER_CLIENT_SECRET"].presence ||
            Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_SECRET"])

          if token.empty?
            raise "TWITTER_CLIENT_ID is required" if effective_id.empty?
            raise "TWITTER_CLIENT_SECRET is required" if effective_secret.empty?
            persist_credentials!(updates) if updates.any?
            replace_client!
            true
          else
            apply_credentials_probe!(
              updates.merge("TWITTER_TOKEN" => token),
              rejection_message: "Twitter token was rejected",
            )
          end
        ensure
          token = nil
        end

        def clear_credentials!
          clear_oauth_token_file!
          persist_credentials!(
            "TWITTER_TOKEN" => nil,
            "TWITTER_REFRESH_TOKEN" => nil,
          )
          replace_client!
        end

        def oauth_call(callback_url:, state:)
          load_credentials!
          client_id = Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_ID"])
          client_secret = Emcp.sanitize_env_value(ENV["TWITTER_CLIENT_SECRET"])
          raise "TWITTER_CLIENT_ID is required — enter it above and try Retrieve again" if client_id.empty?
          raise "TWITTER_CLIENT_SECRET is required — enter it above and try Retrieve again" if client_secret.empty?

          code_verifier = pkce_verifier
          code_challenge = pkce_challenge(code_verifier)
          query = {
            response_type: "code",
            client_id: client_id,
            redirect_uri: callback_url,
            scope: oauth_scopes,
            state: state,
            code_challenge: code_challenge,
            code_challenge_method: "S256",
          }
          {
            authorization_url: "https://x.com/i/oauth2/authorize?#{URI.encode_www_form(query)}",
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

        def oauth_scopes
          custom = Emcp.sanitize_env_value(ENV["TWITTER_OAUTH_SCOPES"])
          return custom if custom.present?

          scopes = DEFAULT_READ_SCOPES.dup
          scopes.concat(DEFAULT_WRITE_SCOPES) if allow_write_methods?
          scopes.join(" ")
        end

        protected

        def credential_env_keys
          %w[
            TWITTER_CLIENT_ID
            TWITTER_CLIENT_SECRET
            TWITTER_TOKEN
            TWITTER_REFRESH_TOKEN
          ]
        end

        def oauth_access_env = "TWITTER_TOKEN"
        def oauth_refresh_env = "TWITTER_REFRESH_TOKEN"

        def replace_client!
          @client = build_client
        end

        def refresh_service_token!
          load_credentials!
          replace_client!
          @client.refresh_access_token!
        end

        private

        def oauth_app_credential_updates(params)
          updates = {}
          client_id = Emcp.sanitize_env_value(params["twitter_client_id"])
          client_secret = Emcp.sanitize_env_value(params["twitter_client_secret"])
          updates["TWITTER_CLIENT_ID"] = client_id if client_id.present?
          updates["TWITTER_CLIENT_SECRET"] = client_secret if client_secret.present?
          updates
        ensure
          client_secret = nil
        end

        def persist_oauth_app_credentials!(params)
          updates = oauth_app_credential_updates(params)
          persist_credentials!(updates) if updates.any?
        end

        def build_client
          Client.new(on_token_refresh: method(:persist_refreshed_token!))
        end

        def persist_refreshed_token!(access_token:, refresh_token:, body:)
          persist_refreshed_oauth_token!(
            access_token: access_token,
            refresh_token: refresh_token,
            body: body,
          )
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

        def api_get(path, query: {})
          api_response { @client.get(path, query: query) }
        end

        def api_post(path, body:)
          api_response { @client.post(path, body: body) }
        end

        def api_delete(path)
          api_response { @client.delete(path) }
        end
      end
    end
  end
end

Emcp.register_integration(Emcp::Servers::Twitter::Server)
