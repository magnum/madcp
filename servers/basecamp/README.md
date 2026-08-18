# Basecamp

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for [Basecamp](https://basecamp.com), backed by the official [`basecamp/basecamp-cli`](https://github.com/basecamp/basecamp-cli). Also exposes the `basecamp://skill` resource.

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/basecamp/mcp
```

Operator UI: `/servers/basecamp/auth`

## Credentials

1. On a machine with a browser: `basecamp auth login` (re-login if tokens stop working — this is not a developer-portal renewal).
2. Copy the token: `basecamp auth token --quiet`
3. Set the numeric **account ID** (from `https://3.basecamp.com/<account_id>/…` or `basecamp accounts list`).
4. Paste **account ID**, then **token**, into `/servers/basecamp/auth`.

CLI config/cache live under `./data/cli/basecamp` and `./data/cli/basecamp-cache` in Docker.

## Environment

| Variable | Purpose |
| --- | --- |
| `BASECAMP_TOKEN` | Access token (also set via the auth form) |
| `BASECAMP_ACCOUNT_ID` | Default account ID |
| `BASECAMP_ALLOW_WRITE` | Enable write tools |
| `BASECAMP_TIMEOUT` | CLI timeout seconds (default `30`) |
| `BASECAMP_NO_KEYRING` | Set in the image (`1`) for file-backed credentials in Docker |

## Tools

About **38** tools (projects, todos, cards, messages, comments, chat, files, schedule, search, people, notifications, and more). Mutations are gated by `BASECAMP_ALLOW_WRITE`.

## Files

- `server.rb` — MCP tools and auth form
- `basecamp_client.rb` — thin CLI wrapper
- `skills/basecamp/SKILL.md` — vendored agent skill
