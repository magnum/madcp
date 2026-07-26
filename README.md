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
│   └── hey/
│       ├── server.rb
│       └── hey_client.rb
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
```

`/tools/<tool>` is a convenience API for testing and automation. MCP clients
use JSON-RPC `tools/list` and `tools/call` through `/mcp`; MCP does not define a
separate HTTP path for every tool.

## Read/write policy

All integrations are read-only by default:

```dotenv
MADCP_ALLOW_WRITE=false
```

Enable writes globally or override one integration:

```dotenv
HEY_ALLOW_WRITE=true
BASECAMP_ALLOW_WRITE=false
FATTUREINCLOUD_ALLOW_WRITE=false
```

The integration marks mutations with `write: true`. MADCP enforces the policy
for both MCP calls and direct `/tools/<tool>` calls.

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

The image builds both CLIs. Named volumes preserve:

- MADCP-persisted integration values under `/app/data`;
- Basecamp CLI configuration/cache;
- HEY CLI configuration.

## Authentication

`MADCP_OAUTH_USERNAME` and `MADCP_OAUTH_PASSWORD` protect each integration's
authorization flow and credential-management form. Each MCP resource has its
own OAuth issuer:

```text
/servers/hey
/servers/basecamp
/servers/fattureincloud
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

External OAuth token retrieval is an integration capability, separate from the
OAuth issuer MADCP exposes to MCP clients. Its launch always requires the MADCP
operator username and password. Callback state is random, expires after five
minutes, and can be used only once. Provider tokens are shown only in the
callback HTML body for copying; they are never put in response headers or URLs.

Fatture in Cloud defaults to the least-privilege scopes
`entity.clients:r entity.suppliers:r issued_documents.invoices:r archive:r`.
Override them with `FATTUREINCLOUD_OAUTH_SCOPES`. Write tools forward raw JSON
objects and remain subject to MADCP's write gate.

References:

- [Authorization code flow](https://developers.fattureincloud.it/docs/authentication/code-flow/vanilla-code/)
- [API scopes](https://developers.fattureincloud.it/docs/basics/scopes/)
- [Ruby SDK reference](https://github.com/fattureincloud/fattureincloud-ruby-sdk)

The OAuth token store is currently in memory. Restarting MADCP invalidates MCP
OAuth sessions, while integration/CLI credentials persist in volumes. A
persistent multi-instance OAuth store is a future production requirement.

## Local development

Ruby 3.2+ and the relevant CLIs must be in `PATH`.

```bash
bundle install
cp .env.example .env
set -a; . ./.env; set +a
bundle exec ruby server.rb
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
