# Twitter / X

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for the [X API v2](https://developer.x.com/en/docs/twitter-api) (users, posts, timelines, search, likes, follows, bookmarks) via `Net::HTTP` and OAuth 2.0 user context.

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/twitter/mcp
```

Operator UI: `/servers/twitter/auth`

## Credentials

1. Create an app in the [X Developer Portal](https://developer.x.com/) and enable **OAuth 2.0**.
2. Set `TWITTER_CLIENT_ID` and `TWITTER_CLIENT_SECRET` (confidential client).
3. Register this callback URL as an allowed redirect URI:

```text
${MADCP_PUBLIC_URL}/servers/twitter/oauth_callback
```

4. Open `/servers/twitter/auth` and choose **Retrieve OAuth token** (or paste a user access token).

MadCP uses authorization code + PKCE through the same host harness as Fatture in Cloud. The full token response (including `refresh_token` when present) is stored under:

```text
data/twitter/oauth_token.json
```

## Environment

| Variable | Purpose |
| --- | --- |
| `TWITTER_CLIENT_ID` | OAuth 2.0 client ID |
| `TWITTER_CLIENT_SECRET` | OAuth 2.0 client secret |
| `TWITTER_TOKEN` | User access token (managed / paste) |
| `TWITTER_REFRESH_TOKEN` | Refresh token (managed) |
| `TWITTER_OAUTH_SCOPES` | Space-separated scopes (defaults cover tweet/user/follow/like/bookmark + `offline.access`) |
| `TWITTER_ALLOW_WRITE` | Enable write tools |
| `TWITTER_TIMEOUT` | HTTP timeout seconds (default `30`) |

## Notes

- API availability and rate limits depend on your X developer **tier**.
- Media upload is out of scope (often needs OAuth 1.0a separately).
- Replies use `twitter_tweet_create` with `payload.reply.in_reply_to_tweet_id`.

## Tools

About **22** tools. Mutations are gated by `TWITTER_ALLOW_WRITE`.

## Files

- `server.rb` — MCP tools, OAuth retrieval, auth form
- `twitter_client.rb` — HTTP client + token exchange/refresh
