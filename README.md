# MadCP

MadCP is a self-hosted Ruby host for multiple [Model Context Protocol](https://modelcontextprotocol.io/) integrations. It keeps HTTP transport, OAuth 2.1, dynamic client registration, login/logout views, tool routing, and the read/write policy in one wrapper. Integration-specific code lives under `servers/<server_id>/`.

Use it as a Custom Connector from Claude Desktop, Claude on the web, Claude mobile, or Cowork — each integration has its own MCP endpoint and OAuth issuer.

## Integrations

| Integration | Docs | Upstream | Tools (approx.) |
| --- | --- | --- | ---: |
| HEY | [README](servers/hey/README.md) | [`basecamp/hey-cli`](https://github.com/basecamp/hey-cli) | 30 |
| Basecamp | [README](servers/basecamp/README.md) | [`basecamp/basecamp-cli`](https://github.com/basecamp/basecamp-cli) | 38 |
| Fatture in Cloud | [README](servers/fattureincloud/README.md) | [API v2](https://developers.fattureincloud.it/) | 22 |
| Google Workspace | [README](servers/googleworkspace/README.md) | [`googleworkspace/cli`](https://github.com/googleworkspace/cli) (`gws`) | 18 |
| Toggl Track | [README](servers/toggltrack/README.md) | [API v9](https://engineering.toggl.com/docs/track/) | 22 |
| Bluesky | [README](servers/bluesky/README.md) | [AT Protocol](https://docs.bsky.app/) | 22 |
| Twitter / X | [README](servers/twitter/README.md) | [API v2](https://developer.x.com/en/docs/twitter-api) | 22 |

Roughly **170 tools** total. Mutations are marked `write: true` and stay disabled until you opt in per integration (or globally). Setup, credentials, env vars, and tool notes for each server live in that server’s README.

## Server folders and Git submodules

Every directory under `servers/` is shaped as a future **Git submodule**: one folder per integration, with a root `server.rb` that registers itself (and its own `README.md`). MadCP discovers only `servers/*/server.rb` and does not require integration code inside `lib/`.

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
│   ├── README.md
│   ├── server.rb
│   └── …
├── views/                     # HTML UI (+ partials)
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
- `GET /logout` — Basic Auth sign-out challenge for the operator UI

## Request logging

Every HTTP request (except `/healthz`) is logged to **file and stdout** (same line):

`logs/requests.logs` (override with `MADCP_REQUEST_LOG`): timestamp, IP, HTTP method, path, status, duration, user-agent, plus when present `server_id`, MCP `mcp_method`, tool `command`, and `arguments` / `params` (secrets redacted; truncated via `MADCP_REQUEST_LOG_MAX_CHARS`). Response bodies are not logged.

With Docker Compose, `./logs` is bind-mounted to `/app/logs`.

MCP client URLs look like:

```text
https://madcp.example.com/servers/hey/mcp
https://madcp.example.com/servers/basecamp/mcp
https://madcp.example.com/servers/fattureincloud/mcp
https://madcp.example.com/servers/googleworkspace/mcp
https://madcp.example.com/servers/toggltrack/mcp
https://madcp.example.com/servers/bluesky/mcp
https://madcp.example.com/servers/twitter/mcp
```

## Read/write policy

Integrations are read-only by default:

```dotenv
MADCP_ALLOW_WRITE=false
MADCP_MAX_CHARS=100000
```

Enable writes globally or per integration (see each [server README](#integrations) for the flag name):

```dotenv
HEY_ALLOW_WRITE=true
BASECAMP_ALLOW_WRITE=false
FATTUREINCLOUD_ALLOW_WRITE=false
GOOGLEWORKSPACE_ALLOW_WRITE=false
TOGGLTRACK_ALLOW_WRITE=false
BLUESKY_ALLOW_WRITE=false
TWITTER_ALLOW_WRITE=false
```

`MADCP_MAX_CHARS` caps tool text returned to the MCP client (default `100000`, roughly aligned with Claude Code’s default MCP output budget). It does not change upstream pagination or API quotas.

## Docker quick start

```bash
cp .env.example .env
# Edit MADCP_PUBLIC_URL, MADCP_SECRET_KEY, data/auth_tokens, data/auth_users, allowed hosts/origins, write flags.
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
./data/                  → /app/data          (auth_tokens, auth_users, integration credentials, MCP OAuth store)
./data/cli/basecamp      → Basecamp CLI config
./data/cli/basecamp-cache
./data/cli/hey
./data/cli/gws           → Google Workspace CLI config
```

The image builds the Basecamp, HEY, and Google Workspace CLIs.

## Authentication

MadCP has **two independent auth planes**:

1. **App auth** — operator UI + optional static MCP Bearer
2. **MCP OAuth** — Claude Custom Connectors get their own access/refresh tokens under `data/_oauth/<server_id>.json`

Changing app tokens/users does **not** revoke already-issued MCP OAuth tokens. External provider OAuth (Fatture, Twitter, …) is separate again (`data/<server_id>/`).

### App auth (`data/auth_users` + `data/auth_tokens`)

| Mechanism | File | Header |
|-----------|------|--------|
| Username / password | `data/auth_users` | `Authorization: Basic …` |
| Static bearer | `data/auth_tokens` | `Authorization: Bearer <token>` |

Password digests in `auth_users` are `HMAC-SHA256(MADCP_SECRET_KEY, password)` (hex). Set `MADCP_SECRET_KEY` (or `SECRET_KEY`) in `.env`.

```bash
cp auth_users.example data/auth_users
cp auth_tokens.example data/auth_tokens
chmod 600 data/auth_users data/auth_tokens
# add MADCP_SECRET_KEY to .env, then:
MADCP_SECRET_KEY=... ruby scripts/hash_auth_password.rb user1 'your-password' >> data/auth_users
```

Example `auth_users`:

```text
user1:a1b2c3…64hex… # primary
# olduser:deadbeef… # disabled
```

Example `auth_tokens`:

```text
tok_live_abc123 # claude-desktop
tok_live_def456 # cowork
# tok_old_revoked # disabled
```

- **Operator UI** (browser): HTTP Basic Auth with `auth_users`, or Bearer from `auth_tokens`
- **MCP / curl**: Bearer from `auth_tokens` (or MadCP-issued OAuth access tokens)
- Both files reload when their mtime changes (no restart needed)
- Optional bootstrap token: `MADCP_AUTH_TOKEN` is merged into the token store

### MCP clients (Claude Custom Connectors)

Each integration is its own OAuth issuer (`/servers/<id>`). MadCP supports authorization code + PKCE, refresh tokens, revocation, dynamic client registration, and protected-resource metadata. You can also call MCP with a static Bearer from `auth_tokens`.

MCP OAuth clients and tokens are persisted under `data/_oauth/<server_id>.json`, so restarting the container does not force Claude to re-authenticate. Short-lived auth codes and login states stay in memory.

If updating integration credentials fails while Claude is waiting, use **Continue to Claude anyway** on the auth page so the MCP handshake can finish without blocking the client.

Auth form fields are pre-filled from the current environment / stored credentials. Values loaded from `.env` / `credentials.env` are trimmed; anything from `#` onward (including `# optional` / `# required` placeholders) is stripped at boot and whenever credentials are read.

Per-integration credential setup is documented in each server README linked [above](#integrations).
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

## License

MadCP is released under the [MIT License](LICENSE).

Copyright (c) 2026 Antonio Molinari.
