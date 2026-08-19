# Bluesky

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for the [Bluesky AT Protocol](https://docs.bsky.app/) (profiles, feeds, posts, search, graph, likes, notifications) via `Net::HTTP`.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/bluesky/mcp
```

Operator UI: `/servers/bluesky/auth`

## Credentials

1. Create an **App Password** in Bluesky Settings (do not use your account password).
2. Paste your handle (or email) and app password into `/servers/bluesky/auth`.
3. Optional: set a custom PDS host if the account is not on `bsky.social`.

EmCP calls `com.atproto.server.createSession`, stores access/refresh JWTs under `data/bluesky/credentials.env`, and refreshes on `401` or `400 ExpiredToken` / `InvalidToken` (AT Proto convention), falling back to a new `createSession` if refresh fails.

ATProto OAuth (PAR/DPoP/client-metadata) is intentionally not used; app passwords remain the practical personal-bot path.

## Security note

Session JWTs (`accessJwt` / `refreshJwt`) are redacted to `[REDACTED]` in tool responses.

## Environment

| Variable | Purpose |
| --- | --- |
| `BLUESKY_HANDLE` | Handle or login email |
| `BLUESKY_APP_PASSWORD` | App password |
| `BLUESKY_PDS_HOST` | PDS base URL (default `https://bsky.social`) |
| `BLUESKY_ACCESS_JWT` | Session access token (managed) |
| `BLUESKY_REFRESH_JWT` | Session refresh token (managed) |
| `BLUESKY_DID` | Authenticated DID (managed) |
| `BLUESKY_ALLOW_WRITE` | Enable write tools |
| `BLUESKY_TIMEOUT` | HTTP timeout seconds (default `30`) |

## Tools

About **22** tools. Mutations are gated by `BLUESKY_ALLOW_WRITE`.

## Files

- `server.rb` — MCP tools and auth form
- `bluesky_client.rb` — HTTP client with session create/refresh
