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

About **22** tools, including:

- Typed Docs / Sheets / Drive helpers (Drive file tools default to shared-drive-friendly flags: `supportsAllDrives`, etc.)
- `googleworkspace_doc_batch_update` — Docs `batchUpdate` as **direct edits** only (`writeControl` supports revision IDs, not suggestion mode)
- Drive comments — `googleworkspace_drive_comments_list`, `googleworkspace_drive_comment_get`, `googleworkspace_drive_comment_create`, `googleworkspace_drive_comment_reply` (reply can `resolve` / `reopen`)
- `googleworkspace_discover` / `googleworkspace_schema`
- `googleworkspace_api_read` — read-ish Discovery methods
- `googleworkspace_api_call` — any Discovery method (`write: true`)

### Comments vs direct edits

The public Docs API has **no suggestion/review write mode** (`writeControl` only has `targetRevisionId` / `requiredRevisionId`). For review notes without rewriting the document, use Drive comments.

| Goal | Tool |
| --- | --- |
| Leave a review comment on a Doc/file | `googleworkspace_drive_comment_create` |
| Reply / resolve a comment | `googleworkspace_drive_comment_reply` |
| Change document content | `googleworkspace_doc_batch_update` (direct edit) |

Optional `anchor_line` / `quoted_text` / `anchor` on create are best-effort. Google Workspace editor apps treat API-defined anchors as **unanchored** in the UI (comments still appear under All Comments). True paragraph pin-to-text like the Docs UI is not fully available via the Drive Comments API.

`gws` builds its command tree from Google Discovery documents, so newly published methods can be used without changing MadCP. The CLI is community-driven and is not an officially supported Google product.

## Files

- `server.rb` — MCP tools and auth form
- `googleworkspace_client.rb` — `gws` CLI wrapper
