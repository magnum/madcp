# MADCP

MADCP is a Ruby host for multiple Model Context Protocol integrations. It keeps
HTTP transport, OAuth 2.1, dynamic client registration, login/logout views,
tool routing, and the read/write policy in one wrapper. Integration-specific
code lives under `servers/<server_id>/`.

The initial integrations are:

- `servers/hey/` — 30 tools and the `hey://skill` resource, backed by the
  official [`basecamp/hey-cli`](https://github.com/basecamp/hey-cli)
- `servers/basecamp/` — 38 tools and the `basecamp://skill` resource, backed by
  the official [`basecamp/basecamp-cli`](https://github.com/basecamp/basecamp-cli)
- `servers/fattureincloud/` — 22 tools for companies, archive documents, issued
  invoices, clients, and suppliers, using the v2 API directly through `Net::HTTP`
- `servers/googleworkspace/` — typed Docs, Sheets, and Drive tools plus safe
  dynamic access to every Google Workspace API exposed by
  [`googleworkspace/cli`](https://github.com/googleworkspace/cli)
- `servers/toggltrack/` — 22 tools for me, organizations, workspaces, projects,
  tags, and time entries through the
  [Toggl Track API v9](https://engineering.toggl.com/docs/track/)

The existing `hey-mcp` and `basecamp-mcp` repositories are not imported or
modified. The two directories included here are self-contained prototypes that
can later be replaced by Git submodules.

## Architecture

```text
madcp/
├── lib/madcp/
│   ├── app.rb              # shared HTTP routes and MCP transport
│   ├── config.rb           # environment configuration
│   ├── integration.rb      # integration contract and tool DSL
│   ├── oauth_provider.rb   # OAuth 2.1 + PKCE + dynamic registration
│   ├── registry.rb         # discovers servers/*/server.rb
│   └── renderer.rb         # shared ERB rendering
├── servers/
│   ├── basecamp/
│   │   ├── server.rb
│   │   └── basecamp_client.rb
│   ├── fattureincloud/
│   │   ├── server.rb
│   │   └── fattureincloud_client.rb
│   ├── googleworkspace/
│   │   ├── server.rb
│   │   └── googleworkspace_client.rb
│   ├── hey/
│   │   ├── server.rb
│   │   └── hey_client.rb
│   └── toggltrack/
│       ├── server.rb
│       └── toggltrack_client.rb
├── views/
└── server.rb
```

`Madcp::Registry` discovers only `servers/*/server.rb`. A server folder must
define a subclass of `Madcp::Integration` and register it:

```ruby
module Madcp
  module Servers
    module Example
      class Server < Integration
        server_id "example"
        display_name "Example"

        def configure_tools
          define_tool(
            name: "example_ping",
            description: "Return a ping.",
          ) { text_response("pong") }
        end
      end
    end
  end
end

Madcp.register_integration(Madcp::Servers::Example::Server)
```

The integration owns:

- tool schemas and CLI/API calls;
- which tools are writes (`write: true`);
- credential fields, validation, persistence, and logout;
- integration name, version, and instructions.

MADCP owns:

- server discovery;
- OAuth and bearer-token validation;
- MCP JSON-RPC transport;
- the global/per-server write gate;
- common HTML and JSON endpoints.

## Endpoints

For each `<server_id>`:

- `GET /servers/` — integration index (HTML; add `?format=json` for JSON)
- `GET /servers/<server_id>/auth` — credential management and OAuth login view
- `POST /servers/<server_id>/oauth` — authenticated external OAuth token retrieval
  launch, available only when the integration opts in
- `GET /servers/<server_id>/oauth_callback` — one-time external OAuth callback
  that displays the provider response with `no-store` and `no-referrer`
- `GET /servers/<server_id>/auth/logout` — revoke MADCP sessions and optionally clear CLI credentials
- `GET /servers/<server_id>/tools` — tool catalog and enabled/write status
- `POST /servers/<server_id>/tools/<tool>` — direct authenticated tool invocation
- `POST /servers/<server_id>/mcp` — standard Streamable HTTP MCP endpoint
- `GET /healthz` — wrapper and integration status

The URL to configure in an MCP client is the MCP endpoint, for example:

```text
https://madcp.example.com/servers/hey/mcp
https://madcp.example.com/servers/basecamp/mcp
https://madcp.example.com/servers/fattureincloud/mcp
https://madcp.example.com/servers/googleworkspace/mcp
https://madcp.example.com/servers/toggltrack/mcp
```

`/tools/<tool>` is a convenience API for testing and automation. MCP clients
use JSON-RPC `tools/list` and `tools/call` through `/mcp`; MCP does not define a
separate HTTP path for every tool.

## Read/write policy

All integrations are read-only by default:

```dotenv
MADCP_ALLOW_WRITE=false
MADCP_MAX_CHARS=100000
```

Enable writes globally or override one integration:

```dotenv
HEY_ALLOW_WRITE=true
BASECAMP_ALLOW_WRITE=false
FATTUREINCLOUD_ALLOW_WRITE=false
GOOGLEWORKSPACE_ALLOW_WRITE=false
TOGGLTRACK_ALLOW_WRITE=false
```

The integration marks mutations with `write: true`. MADCP enforces the policy
for both MCP calls and direct `/tools/<tool>` calls.

`MADCP_MAX_CHARS` is the shared maximum text returned by any integration tool.
It limits only the response passed to the MCP client; it does not change API
pagination, request payloads, or upstream API quotas. The default of 100,000
characters approximates Claude Code's default 25,000-token MCP output limit;
the exact character-to-token ratio depends on the returned content.

## Docker quick start

```bash
cp .env.example .env
# Edit MADCP_PUBLIC_URL, credentials, allowed host/origin, and write policy.
docker compose up --build
```

The external port is configurable while the container port remains `8765`:

```dotenv
MADCP_HOST_PORT=8877
```

Open `http://localhost:8877/servers/` locally, or configure the public MCP URLs
through your HTTPS tunnel/reverse proxy.

The image builds the Basecamp, HEY, and Google Workspace CLIs. Durable state is
bind-mounted from the host `./data` directory:

```text
./data/                  → /app/data          (integration credentials, OAuth store)
./data/cli/basecamp      → Basecamp CLI config
./data/cli/basecamp-cache
./data/cli/hey
./data/cli/gws           → Google Workspace CLI config
```

`./data` is gitignored. If you previously used Compose named volumes, copy them
once into `./data` (or re-paste credentials through `/servers/*/auth`) after
switching.

## Authentication

`MADCP_OAUTH_USERNAME` and `MADCP_OAUTH_PASSWORD` protect each integration's
authorization flow and credential-management form. Each MCP resource has its
own OAuth issuer:

```text
/servers/hey
/servers/basecamp
/servers/fattureincloud
/servers/googleworkspace
/servers/toggltrack
```

MADCP supports authorization code + PKCE, refresh tokens, token revocation,
dynamic client registration, protected-resource metadata, and an optional
static `MADCP_AUTH_TOKEN`.

Integration credentials are separate:

- HEY: paste `hey auth token --quiet` into `/servers/hey/auth`;
- Basecamp: paste `basecamp auth token --quiet` and the account ID into
  `/servers/basecamp/auth`.
- Fatture in Cloud: paste an access token, or enter the MADCP operator
  credentials and choose **Retrieve OAuth token**. Configure
  `FATTUREINCLOUD_CLIENT_ID` and `FATTUREINCLOUD_CLIENT_SECRET` first. The
  redirect URI registered at Fatture in Cloud must exactly match
  `${MADCP_PUBLIC_URL}/servers/fattureincloud/oauth_callback`.
- Google Workspace: paste the JSON from `gws auth export --unmasked` into
  `/servers/googleworkspace/auth`. Leave the short-lived access token empty —
  `GOOGLE_WORKSPACE_CLI_TOKEN` overrides the refresh-token file and expires
  quickly. Prefer an exported OAuth credential or service-account JSON. Set
  `GOOGLE_WORKSPACE_PROJECT_ID` for quota attribution.
- Toggl Track: paste the personal API token plus organization ID and workspace
  ID into `/servers/toggltrack/auth`. MADCP authenticates with HTTP Basic Auth
  as `token:api_token` against the v9 API.

External OAuth token retrieval is an integration capability, separate from the
OAuth issuer MADCP exposes to MCP clients. Its launch always requires the MADCP
operator username and password. Callback state is random, expires after five
minutes, and can be used only once. Provider tokens are shown only in the
callback HTML body for copying; they are never put in response headers or URLs.

Fatture in Cloud defaults to the least-privilege scopes
`entity.clients:r entity.suppliers:r issued_documents.invoices:r archive:r`.
Override them with `FATTUREINCLOUD_OAUTH_SCOPES`. Write tools forward raw JSON
objects and remain subject to MADCP's write gate.

### Google Workspace tools

Common Docs and Sheets editing operations have typed MCP tools. Drive file
listing and metadata reads are also typed. The integration additionally exposes:

- `googleworkspace_discover` and `googleworkspace_schema` for dynamic discovery;
- `googleworkspace_api_read` for method names classified as read-only;
- `googleworkspace_api_call` for any Discovery API method.

`googleworkspace_api_call` and every typed mutation are marked `write: true`.
This keeps the fully dynamic CLI surface available without allowing arbitrary
mutations when `GOOGLEWORKSPACE_ALLOW_WRITE=false`. Before using another API,
inspect its exact parameters with the schema tool.

The `gws` CLI is community-driven and is not an officially supported Google
product. It builds its command tree dynamically from Google Discovery documents,
so newly published Workspace methods can be used without changing MADCP.

Headless credential setup:

```bash
# Run on a machine with a browser and gws installed.
gws auth login
gws auth export --unmasked > googleworkspace-credentials.json
```

Paste that JSON into the integration auth form, or mount it in the container and
set `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`. A service-account JSON credential
is also accepted where domain-wide delegation and API scopes are configured.

References:

- [Authorization code flow](https://developers.fattureincloud.it/docs/authentication/code-flow/vanilla-code/)
- [API scopes](https://developers.fattureincloud.it/docs/basics/scopes/)
- [Ruby SDK reference](https://github.com/fattureincloud/fattureincloud-ruby-sdk)

MCP OAuth clients, access tokens, and refresh tokens are persisted under
`data/_oauth/<server_id>.json` (under the host `./data` bind mount). Restarting
MADCP keeps Claude Custom Connector sessions valid. Short-lived authorization
codes and login states stay in memory. A shared multi-instance OAuth store is
still a future production requirement if you run more than one MADCP replica.

## Live code editing (Docker)

Mounting `servers/` as a volume is worth it while you iterate on integrations.
True in-process Ruby class reloading is not: tools, the registry, and OAuth
providers are built once at boot. Restart the process instead.

```bash
cp docker-compose.override.example.yml docker-compose.override.yml
docker compose up -d --build
```

The override bind-mounts `servers/`, `lib/`, `views/`, and the entry scripts,
then runs `scripts/run-with-reload.sh`.

Reload options:

```bash
# Explicit (always works)
touch data/restart.txt

# Automatic: MADCP_AUTO_RELOAD=1 in the override polls .rb/.erb under
# servers/, lib/, and views/ and restarts the Ruby process on change.
```

Still rebuild the image when `Dockerfile`, `Gemfile`, or CLI binaries change.

`docker-compose.override.yml` is gitignored so production hosts can keep the
plain `docker-compose.yml` (image-baked code + `./data` only).

## Local development

Ruby 3.2+ and the relevant CLIs must be in `PATH`.

```bash
bundle install
cp .env.example .env
set -a; . ./.env; set +a
bundle exec ruby server.rb
# or, with the same restart marker / auto-reload behavior:
# MADCP_ROOT=. MADCP_AUTO_RELOAD=1 ./scripts/run-with-reload.sh
```

Run checks:

```bash
bundle exec ruby -Itest test/app_test.rb
```

## Future Git submodules

The folder boundary is intentionally compatible with submodules:

```bash
git rm -r servers/hey
git submodule add <hey-server-repository> servers/hey
```

Each submodule only needs a root `server.rb` that registers one integration.
Its clients, tests, and supporting files can remain inside the same folder.
MADCP does not require integration code to be copied into `lib/`.
