# Toggl Track

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for the [Toggl Track API v9](https://engineering.toggl.com/docs/track/) (me, organizations, workspaces, projects, tags, time entries) via `Net::HTTP`.

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/toggltrack/mcp
```

Operator UI: `/servers/toggltrack/auth`

## Credentials

1. Create a personal API token in your Toggl Track profile.
2. Note your **organization ID** and **workspace ID**.
3. Paste them into `/servers/toggltrack/auth`.

MadCP authenticates with HTTP Basic Auth as `token:api_token` (username = API token, password literal `api_token`), as documented by Toggl.

## Security note

Toggl returns `api_token` fields in cleartext on some profile/workspace payloads. The MadCP HTTP client **redacts** nested `api_token` values to `[REDACTED]` before tool results are returned to MCP clients, so tokens do not leak into conversation context.

## Environment

| Variable | Purpose |
| --- | --- |
| `TOGGLTRACK_TOKEN` | Personal API token |
| `TOGGLTRACK_ORGANIZATION_ID` | Default organization |
| `TOGGLTRACK_WORKSPACE_ID` | Default workspace when a tool omits `workspace_id` |
| `TOGGLTRACK_ALLOW_WRITE` | Enable write tools |
| `TOGGLTRACK_TIMEOUT` | HTTP timeout seconds (default `30`) |

## Tools

About **22** tools. Workspace-scoped calls use `TOGGLTRACK_WORKSPACE_ID` when the argument is omitted. Mutations are gated by `TOGGLTRACK_ALLOW_WRITE`.

## Files

- `server.rb` — MCP tools and auth form
- `toggltrack_client.rb` — HTTP client (includes response redaction)
