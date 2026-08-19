# EmCP

EmCP is a self-hosted [Model Context Protocol](https://modelcontextprotocol.io/) host built on **Rails 8**, based on the [`railsapp`](../railsapp) template.

Operator UI uses **session login** (`User`). MCP clients authenticate with **ApiKey** Bearer tokens and/or per-server **OAuth 2.1** (PKCE). Integration code still lives under `servers/<code>/` as STI subclasses of `McpServer`.

> The previous Sinatra host is archived under [`legacy/`](legacy/) on this branch for reference while the port is validated. Do not merge to `main` until this branch is green.

## Quick start

```bash
cp .env.example .env   # or set vars below
bundle install
bin/rails db:prepare
bin/rails db:seed
bin/dev
```

### Production env (Kamal)

Keep only deploy-critical secrets in `.kamal/secrets` / `deploy.yml` (`RAILS_MASTER_KEY`, Google OmniAuth, `APP_HOST`).

Put the rest in a single file on the server volume (not in git):

```bash
# on the deploy host
install -m 600 /dev/stdin /data/emcp/storage/.env < .env   # from your machine via scp/ssh
```

That file is mounted at `/rails/storage/.env` and loaded at boot for web + worker. Existing Kamal/env values are not overridden.

### Required env

| Variable | Purpose |
| --- | --- |
| `EMCP_PUBLIC_URL` | Public base URL (no trailing slash), used in MCP/OAuth metadata |
| `EMCP_USER1_PASSWORD` | Password for seeded operator `user1@emcp.local` (dev default: `emcp-dev-password`) |
| `API_KEY_HMAC_SECRET_KEY` | HMAC secret for ApiKey digests |

### Operator login

- Email: `user1@emcp.local`
- Password: `EMCP_USER1_PASSWORD` (or the development default)
- Integrations: `/` or `/servers`
- Auth per server: `/servers/<code>/auth`

### MCP clients

Endpoint per integration:

```text
${EMCP_PUBLIC_URL}/servers/<code>/mcp
```

**ApiKey (static Bearer)** — in console:

```ruby
User.find_by(email: "user1@emcp.local").api_key!
# => "tkn_usr_..."
```

Send `Authorization: Bearer tkn_usr_...`.

**OAuth 2.1** — discovery:

- `/.well-known/oauth-authorization-server/servers/<code>`
- `/.well-known/oauth-protected-resource/servers/<code>/mcp`

## Architecture

- `McpServer` (AR + STI) owns host behavior formerly in `lib/emcp/integration.rb`
- `servers/<code>/server.rb` registers with `Emcp.register_integration(...)` and overrides tools/auth
- Credentials: encrypted columns + `storage/mcp/<code>/` files for CLI compat
- MCP OAuth clients/tokens: AR tables (`mcp_oauth_*`)

## Integrations

Same set as before: HEY, Basecamp, Fatture in Cloud, Google Workspace, Toggl Track, Bluesky, Twitter/X, TeslaMate. See each `servers/*/README.md`.

## Tests

```bash
bin/rails test test/models/mcp_server_test.rb test/services/mcp_oauth_provider_test.rb test/controllers/mcp_servers
```

## Deploy notes

Prefer Kamal from the railsapp template (`config/deploy.yml`). Wire `API_KEY_HMAC_SECRET_KEY`, `EMCP_PUBLIC_URL`, and `EMCP_USER1_PASSWORD` into secrets. Keep TeslaMate/Postgres and CLI binaries available to the app container as needed.
