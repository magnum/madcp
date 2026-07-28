# Twitter / X

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for the [X API v2](https://developer.x.com/en/docs/twitter-api) (users, posts, timelines, search, likes, follows, bookmarks) via `Net::HTTP` and OAuth 2.0 user context.

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/twitter/mcp
```

Operator UI: `/servers/twitter/auth`

## Credentials

1. Create a **Project + App** in the [X Developer Portal](https://developer.x.com/).
2. Open the app → **User authentication settings** (this section must be enabled explicitly):
   - OAuth 2.0: on
   - Type of App: **Web App, Automated App or Bot** (confidential client)
   - App permissions: **Read and write** (needed for MadCP’s default scopes)
   - Callback URI / Redirect URL — exact match:

```text
https://madcp.m6i.it/servers/twitter/oauth_callback
```

   (or `${MADCP_PUBLIC_URL}/servers/twitter/oauth_callback` for your host — no trailing slash)

   - Website URL: e.g. `https://madcp.m6i.it` (required by X for user auth)
3. Copy the **OAuth 2.0 Client ID** and **Client Secret** into:

```dotenv
TWITTER_CLIENT_ID=...
TWITTER_CLIENT_SECRET=...
```

   Do **not** use the legacy API Key / API Secret (OAuth 1.0a) here.
4. Open `/servers/twitter/auth` → **Retrieve OAuth token**.

MadCP uses authorization code + PKCE. The token response (including `refresh_token`) is stored under:

```text
data/twitter/oauth_token.json
```

### “Something went wrong / weren’t able to give access”

That message is returned by **X**, before MadCP sees the callback. Checklist:

1. Callback URI in the portal is an **exact** copy of the URL MadCP shows (scheme, host, path).
2. User authentication settings are saved (OAuth 2.0 + Web App + Website URL).
3. App permissions match requested scopes (defaults include write/like/follow/bookmark).
4. You are logged into X in the same browser; try a private window without privacy blockers.
5. Client ID is the OAuth 2.0 Client ID, not the API Key.

To debug scopes, temporarily set a minimal set:

```dotenv
TWITTER_OAUTH_SCOPES=tweet.read users.read offline.access
```

(and set App permissions to Read in the portal), then widen again once consent works.
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
