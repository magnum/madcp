# MadCP

MadCP is a self-hosted Ruby host for multiple [Model Context Protocol](https://modelcontextprotocol.io/) integrations. It keeps HTTP transport, OAuth 2.1, dynamic client registration, login/logout views, tool routing, and the read/write policy in one wrapper. Integration-specific code lives under `servers/<server_id>/`.

Use it as a Custom Connector from Claude Desktop, Claude on the web, Claude mobile, or Cowork — each integration has its own MCP endpoint and OAuth issuer.

## Integrations

| Folder | Upstream | Tools (approx.) |
| --- | --- | ---: |
| `servers/hey/` | [`basecamp/hey-cli`](https://github.com/basecamp/hey-cli) + `hey://skill` | 30 |
| `servers/basecamp/` | [`basecamp/basecamp-cli`](https://github.com/basecamp/basecamp-cli) + `basecamp://skill` | 38 |
| `servers/fattureincloud/` | [Fatture in Cloud API v2](https://developers.fattureincloud.it/) via `Net::HTTP` | 22 |
| `servers/googleworkspace/` | [`googleworkspace/cli`](https://github.com/googleworkspace/cli) (`gws`) — Docs, Sheets, Drive + Discovery | 18 |
| `servers/toggltrack/` | [Toggl Track API v9](https://engineering.toggl.com/docs/track/) | 22 |

Roughly **130 tools** total. Mutations are marked `write: true` and stay disabled until you opt in per integration (or globally).

## Server folders and Git submodules

Every directory under `servers/` is shaped as a future **Git submodule**: one folder per integration, with a root `server.rb` that registers itself. MadCP discovers only `servers/*/server.rb` and does not require integration code inside `lib/`.

**Today** those folders live as normal files in this repository so the project stays easy to clone and ship.

**Later** each `servers/<id>/` can be split out and added back as a submodule without changing the host contract:

```bash
git rm -r servers/hey
git submodule add <hey-server-repository> servers/hey
```

## Architecture

```text
madcp/
├── lib/madcp/                 # shared host (HTTP, OAuth, registry, DSL)
├── servers/<server_id>/       # one integration per folder (submodule-ready)
├── views/                     # HTML UI
├── scripts/run-with-reload.sh # optional process restart on code change
├── update_and_restart.sh      # git pull → optional .env edit → compose up
├── data/                      # host bind-mount (gitignored)
└── server.rb
```

MadCP owns discovery, OAuth for MCP clients, MCP JSON-RPC transport, the write gate, and shared HTML/JSON endpoints. Each integration owns tools, credential fields, and CLI/API calls.

## Endpoints

For each `<server_id>`:

- `GET /servers/` — integration index (HTML; `?format=json` for JSON)
- `GET /servers/<server_id>/auth` — credentials + MCP client login
- `POST /servers/<server_id>/auth/continue` — return to Claude/MCP client even if integration credentials fail
- `POST /servers/<server_id>/oauth` — provider OAuth launch (opt-in integrations)
- `GET /servers/<server_id>/oauth_callback` — provider callback (`no-store` / `no-referrer`)
- `POST /servers/<server_id>/auth/save_oauth_token` — save provider token from the callback page
- `GET /servers/<server_id>/auth/logout` — revoke MadCP sessions (optional clear of integration secrets)
- `GET /servers/<server_id>/tools` — tool catalog and write/enabled status
- `POST /servers/<server_id>/tools/<tool>` — direct authenticated tool call (testing)
- `POST /servers/<server_id>/mcp` — Streamable HTTP MCP endpoint
- `GET /healthz` — health and auth status

MCP client URLs look like:

```text
https://madcp.example.com/servers/hey/mcp
https://madcp.example.com/servers/basecamp/mcp
https://madcp.example.com/servers/fattureincloud/mcp
https://madcp.example.com/servers/googleworkspace/mcp
https://madcp.example.com/servers/toggltrack/mcp
```

## Read/write policy

Integrations are read-only by default:

```dotenv
MADCP_ALLOW_WRITE=false
MADCP_MAX_CHARS=100000
```

Enable writes globally or per integration:

```dotenv
HEY_ALLOW_WRITE=true
BASECAMP_ALLOW_WRITE=false
FATTUREINCLOUD_ALLOW_WRITE=false
GOOGLEWORKSPACE_ALLOW_WRITE=false
TOGGLTRACK_ALLOW_WRITE=false
```

`MADCP_MAX_CHARS` caps tool text returned to the MCP client (default `100000`, roughly aligned with Claude Code’s default MCP output budget). It does not change upstream pagination or API quotas.

## Docker quick start

```bash
cp .env.example .env
# Edit MADCP_PUBLIC_URL, MADCP_AUTH_USERNAME/PASSWORD, allowed hosts/origins, write flags.
docker compose up --build -d
# or, on the host after changes:
./update_and_restart.sh
```

Port mapping (container stays on `8765`):

```dotenv
MADCP_HOST_PORT=8877
```

Durable state is bind-mounted from `./data` (gitignored):

```text
./data/                  → /app/data          (integration credentials, MCP OAuth store)
./data/cli/basecamp      → Basecamp CLI config
./data/cli/basecamp-cache
./data/cli/hey
./data/cli/gws           → Google Workspace CLI config
```

The image builds the Basecamp, HEY, and Google Workspace CLIs.

## Authentication

### Operator UI (HTTP Basic Auth)

HTML operator pages (`/servers/`, `/auth`, OAuth callback UI, logout) require HTTP Basic Auth:

```dotenv
MADCP_AUTH_USERNAME=admin
MADCP_AUTH_PASSWORD=change-me
```

MCP protocol endpoints (`/mcp`, token/register/metadata) are **not** behind Basic Auth — they use MadCP OAuth / bearer tokens for Claude and other MCP clients.

Because the browser is already authenticated with Basic Auth, integration auth forms no longer ask for a MadCP username/password.

### MCP clients (Claude Custom Connectors)

Each integration is its own OAuth issuer (`/servers/<id>`). MadCP supports authorization code + PKCE, refresh tokens, revocation, dynamic client registration, protected-resource metadata, and an optional static `MADCP_AUTH_TOKEN`.

MCP OAuth clients and tokens are persisted under `data/_oauth/<server_id>.json`, so restarting the container does not force Claude to re-authenticate. Short-lived auth codes and login states stay in memory.

If updating integration credentials fails while Claude is waiting, use **Continue to Claude anyway** on the auth page so the MCP handshake can finish without blocking the client.

Auth form fields are pre-filled from the current environment / stored credentials. Values loaded from `.env` / `credentials.env` are trimmed; placeholders like `# optional` are ignored.

### Integration credentials

- **HEY** — paste `hey auth token --quiet` into `/servers/hey/auth`
- **Basecamp** — paste `basecamp auth token --quiet` and the account ID into `/servers/basecamp/auth`
- **Fatture in Cloud** — configure `FATTUREINCLOUD_CLIENT_ID` / `FATTUREINCLOUD_CLIENT_SECRET`, register  
  `${MADCP_PUBLIC_URL}/servers/fattureincloud/oauth_callback`, then use **Retrieve OAuth token**.  
  MadCP exchanges the code, can auto-save the access token, stores the full token JSON (including `refresh_token`) in `data/fattureincloud/oauth_token.json`, and offers a paste/save form on the callback page if auto-save fails. Default scopes are least-privilege read; override with `FATTUREINCLOUD_OAUTH_SCOPES`.
- **Google Workspace** — paste `gws auth export --unmasked` JSON into `/servers/googleworkspace/auth`. Leave the short-lived access token empty: `GOOGLE_WORKSPACE_CLI_TOKEN` overrides the refresh-token file and expires quickly. Set `GOOGLE_WORKSPACE_PROJECT_ID` for quota attribution.
- **Toggl Track** — personal API token + organization ID + workspace ID; Basic Auth as `token:api_token` against the v9 API.

### Google Workspace tools

Typed tools cover common Docs, Sheets, and Drive operations (Drive defaults to shared-drive-friendly flags). Also available:

- `googleworkspace_discover` / `googleworkspace_schema`
- `googleworkspace_api_read` — read-ish Discovery methods
- `googleworkspace_api_call` — any Discovery method (`write: true`)

`gws` is community-driven and builds its command tree from Google Discovery documents.

```bash
gws auth login
gws auth export --unmasked > googleworkspace-credentials.json
```

## Live code editing (Docker)

For day-to-day work on integrations, copy the Compose override so `servers/`, `lib/`, and `views/` are bind-mounted and the process can restart without a full image rebuild:

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
docker compose up -d --build
```

Reload:

```bash
touch data/restart.txt
# or rely on MADCP_AUTO_RELOAD=1 (polls .rb/.erb under servers/, lib/, views/)
```

Rebuild the image when `Dockerfile`, `Gemfile`, or CLI binaries change. `docker-compose.override.yml` is gitignored.

## Local development

```bash
bundle install
cp .env.example .env
set -a; . ./.env; set +a
bundle exec ruby server.rb
# MADCP_ROOT=. MADCP_AUTO_RELOAD=1 ./scripts/run-with-reload.sh
```

```bash
bundle exec ruby -Itest test/app_test.rb
```

## References

- [Fatture in Cloud authorization code flow](https://developers.fattureincloud.it/docs/authentication/code-flow/vanilla-code/)
- [Fatture in Cloud API scopes](https://developers.fattureincloud.it/docs/basics/scopes/)
- [Fatture in Cloud Ruby SDK](https://github.com/fattureincloud/fattureincloud-ruby-sdk)
