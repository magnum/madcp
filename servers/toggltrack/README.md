# Toggl Track

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for the [Toggl Track API v9](https://engineering.toggl.com/docs/track/) (me, organizations, workspaces, projects, tags, time entries) via `Net::HTTP`.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/toggltrack/mcp
```

Operator UI: `/servers/toggltrack/auth`

## Credentials

1. Create a personal API token in your Toggl Track profile.
2. Note your **organization ID** and **workspace ID**.
3. Paste them into `/servers/toggltrack/auth`.

EmCP authenticates with HTTP Basic Auth as `token:api_token` (username = API token, password literal `api_token`), as documented by Toggl.

## Security note

Toggl returns `api_token` fields in cleartext on some profile/workspace payloads. The EmCP HTTP client **redacts** nested `api_token` values to `[REDACTED]` before tool results are returned to MCP clients, so tokens do not leak into conversation context.

## Environment

| Variable | Purpose |
| --- | --- |
| `TOGGLTRACK_TOKEN` | Personal API token |
| `TOGGLTRACK_ORGANIZATION_ID` | Default organization |
| `TOGGLTRACK_WORKSPACE_ID` | Default workspace when a tool omits `workspace_id` |
| `TOGGLTRACK_ALLOW_WRITE` | Enable write tools |
| `TOGGLTRACK_TIMEOUT` | HTTP timeout seconds (default `30`) |

## Auth status

The operator UI badge probes `GET /workspaces/:id` when `TOGGLTRACK_WORKSPACE_ID` is set (workspace/org API quota). It falls back to `GET /me` only if no workspace is configured (`/me` is capped at ~30 req/hour). EmCP caches the probe for 10 minutes; the refresh button forces a new check.

## Tools

About **22** tools. Workspace-scoped calls use `TOGGLTRACK_WORKSPACE_ID` when the argument is omitted. Mutations are gated by `TOGGLTRACK_ALLOW_WRITE`.

## Files

- `server.rb` — MCP tools and auth form
- `toggltrack_client.rb` — HTTP client (includes response redaction)
