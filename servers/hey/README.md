# HEY

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for [HEY](https://hey.com) email and related tools, backed by the official [`basecamp/hey-cli`](https://github.com/basecamp/hey-cli). Also exposes the `hey://skill` resource (official CLI agent skill).

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/hey/mcp
```

Operator UI: `/servers/hey/auth`

## Credentials

1. On a machine with a browser: `hey auth login` (or your usual HEY CLI login).
2. Copy the token: `hey auth token --quiet`
3. Paste it into `/servers/hey/auth` (MadCP Basic Auth already covers the operator).

Credentials are stored via the HEY CLI config volume (`./data/cli/hey` in Docker).

## Environment

| Variable | Purpose |
| --- | --- |
| `HEY_ALLOW_WRITE` | Enable write tools (`true` / `false`) |
| `HEY_TIMEOUT` | CLI timeout seconds (default `30`) |
| `HEY_NO_KEYRING` | Set in the image (`1`) so the CLI uses file storage in Docker |

## Tools

About **30** tools (mailboxes, threads, compose/reply, calendars, todos, habits, journal, auth/config helpers). Mutations are `write: true` and gated by `HEY_ALLOW_WRITE`.

For `hey_compose` / `hey_reply`, prefer the `paragraphs` array. MadCP converts plain text to simple HTML before calling the HEY CLI so line breaks are not collapsed by Action Text.

## Files

- `server.rb` — MCP tools and auth form
- `hey_client.rb` — thin CLI wrapper
- `skills/hey/SKILL.md` — vendored agent skill
