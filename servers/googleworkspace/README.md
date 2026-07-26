# Google Workspace

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for Google Docs, Sheets, Drive, and the rest of Workspace APIs exposed by the community [`googleworkspace/cli`](https://github.com/googleworkspace/cli) (`gws`). Typed tools cover common Docs/Sheets/Drive flows; Discovery-backed tools reach everything else.

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/googleworkspace/mcp
```

Operator UI: `/servers/googleworkspace/auth`

## Credentials

Prefer a durable refresh-token export (not a short-lived access token):

```bash
gws auth setup    # once, Google Cloud project + APIs
gws auth login
gws auth status
gws auth export --unmasked
```

Paste the exported JSON into `/servers/googleworkspace/auth`. Leave the short-lived access token field empty: `GOOGLE_WORKSPACE_CLI_TOKEN` overrides the credentials file and expires quickly.

Set `GOOGLE_WORKSPACE_PROJECT_ID` for quota / billing attribution (often missing from the export).

In Docker, CLI config lives under `./data/cli/gws`. MadCP also stores credentials under `data/googleworkspace/`.

## Environment

| Variable | Purpose |
| --- | --- |
| `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` | Path to credentials JSON (set by the auth form) |
| `GOOGLE_WORKSPACE_CLI_TOKEN` | Discouraged short-lived access token |
| `GOOGLE_WORKSPACE_PROJECT_ID` | Cloud project ID |
| `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` | gws config dir (default `/home/madcp/.config/gws` in Docker) |
| `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND` | `file` in Docker |
| `GOOGLEWORKSPACE_ALLOW_WRITE` | Enable write tools |
| `GOOGLEWORKSPACE_TIMEOUT` | CLI timeout seconds (default `60`) |

## Tools

About **18** tools, including:

- Typed Docs / Sheets / Drive helpers (Drive defaults to shared-drive-friendly flags: `supportsAllDrives`, etc.)
- `googleworkspace_doc_batch_update` — Docs `batchUpdate`; set `suggest=true` or `write_mode=SUGGEST` for collaborative suggestion mode instead of direct edits
- `googleworkspace_discover` / `googleworkspace_schema`
- `googleworkspace_api_read` — read-ish Discovery methods
- `googleworkspace_api_call` — any Discovery method (`write: true`)

`gws` builds its command tree from Google Discovery documents, so newly published methods can be used without changing MadCP. The CLI is community-driven and is not an officially supported Google product.

## Files

- `server.rb` — MCP tools and auth form
- `googleworkspace_client.rb` — `gws` CLI wrapper
