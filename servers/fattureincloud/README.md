# Fatture in Cloud

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for [Fatture in Cloud](https://www.fattureincloud.it/) API v2 (companies, archive, invoices, clients, suppliers) using `Net::HTTP` — no CLI binary.

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/fattureincloud/mcp
```

Operator UI: `/servers/fattureincloud/auth`

## Credentials

1. Create an API application in Fatture in Cloud and set:
   - `FATTUREINCLOUD_CLIENT_ID`
   - `FATTUREINCLOUD_CLIENT_SECRET`
2. Register this **exact** redirect URI:

   ```text
   ${MADCP_PUBLIC_URL}/servers/fattureincloud/oauth_callback
   ```

3. In `/servers/fattureincloud/auth`, choose **Retrieve OAuth token** (you are already signed in with MadCP Basic Auth).
4. Complete the Fatture consent screen. The browser returns to MadCP’s callback
   (`/servers/fattureincloud/oauth_callback`). That callback is public (no Basic Auth);
   security is the one-time `state` stored under `data/_oauth/retrieval_states.json`
   (survives process reloads; TTL 10 minutes). Do not reuse an old callback URL.
5. MadCP exchanges the code, can auto-save the access token, and stores the full OAuth JSON (including `refresh_token`) at:

   ```text
   data/fattureincloud/oauth_token.json
   ```

   Access tokens expire in about **24 hours**. On HTTP 401 MadCP automatically exchanges
   `FATTUREINCLOUD_REFRESH_TOKEN` (~1 year from last refresh) for a new access + refresh pair
   and persists them. Keep `FATTUREINCLOUD_CLIENT_ID` / `FATTUREINCLOUD_CLIENT_SECRET`
   configured so refresh can run.

   If auto-save fails, the callback page lets you paste the access token (and optional full JSON including `refresh_token`) back into MadCP.

Optional: set a default `FATTUREINCLOUD_COMPANY_ID` for company-scoped tools.

## Environment

| Variable | Purpose |
| --- | --- |
| `FATTUREINCLOUD_CLIENT_ID` | OAuth app client ID |
| `FATTUREINCLOUD_CLIENT_SECRET` | OAuth app client secret |
| `FATTUREINCLOUD_TOKEN` | Access token (auth form / OAuth callback) |
| `FATTUREINCLOUD_REFRESH_TOKEN` | Refresh token (auto-used on 401; persisted from OAuth) |
| `FATTUREINCLOUD_COMPANY_ID` | Default company for scoped tools |
| `FATTUREINCLOUD_OAUTH_SCOPES` | Override default OAuth scopes (space-separated) |
| `FATTUREINCLOUD_ALLOW_WRITE` | Enable write tools (`true` required for create/modify/delete) |
| `FATTUREINCLOUD_TIMEOUT` | HTTP timeout seconds (default `30`) |

Default OAuth scopes are set in MadCP’s authorize URL — not in Fatture in Cloud’s “Utenti e Permessi” (that page is for sub-users). After changing scopes, **re-run Retrieve OAuth token**; the existing token keeps the old whitelist.

Write access needs **both**:
1. OAuth scopes with `:a` (below)
2. `FATTUREINCLOUD_ALLOW_WRITE=true` (MadCP gate)

```text
entity.clients:a entity.suppliers:a
issued_documents.invoices:a issued_documents.credit_notes:a
issued_documents.quotes:a issued_documents.proformas:a
issued_documents.self_invoices:a
archive:a
received_documents:r situation:r taxes:r cashbook:r calendar:r
```

Document mutations use the existing tools (`fattureincloud_issued_document_create` / `_modify`, clients/suppliers create/modify, etc.). For autofatture, call issued-document tools with `type` / payload for self invoices (`self_invoice`).

## Tools

About **22** tools. Mutations accept raw JSON payloads and are gated by `FATTUREINCLOUD_ALLOW_WRITE`.

## References

- [Authorization code flow](https://developers.fattureincloud.it/docs/authentication/code-flow/vanilla-code/)
- [API scopes](https://developers.fattureincloud.it/docs/basics/scopes/)
- [Ruby SDK reference](https://github.com/fattureincloud/fattureincloud-ruby-sdk)

## Files

- `server.rb` — MCP tools, OAuth retrieval, auth form
- `fattureincloud_client.rb` — HTTP client
