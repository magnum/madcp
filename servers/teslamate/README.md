# TeslaMate

← [Back to project](https://github.com/magnum/madcp)

MadCP integration for a [TeslaMate](https://github.com/teslamate-org/teslamate) PostgreSQL database. Connects **directly to Postgres** (no TeslaMate HTTP API) and exposes analytics reports as MCP tools.

SQL report definitions are adapted from [magnum/teslamate-mcp](https://github.com/magnum/teslamate-mcp) (MIT; originally [cobanov/teslamate-mcp](https://github.com/cobanov/teslamate-mcp)).

## MCP endpoint

```text
${MADCP_PUBLIC_URL}/servers/teslamate/mcp
```

Operator UI: `/servers/teslamate/auth`

## Credentials

1. Create a **read-only** PostgreSQL role with `SELECT` on TeslaMate tables (do **not** use the Compose `teslamate` superuser).
2. Paste a connection URI into the auth form (or set `TESLAMATE_DATABASE_URL`).
3. Keep Postgres on a private network (VPN / Tailscale). Location history should not be public.

Example URI:

```text
postgresql://teslamate_ro:password@teslamate-db:5432/teslamate
```

## Environment

| Variable | Purpose |
| --- | --- |
| `TESLAMATE_DATABASE_URL` | PostgreSQL connection URI (required) |
| `TESLAMATE_REPORT_TIMEZONE` | IANA timezone for daily/monthly buckets (default `UTC`) |
| `TESLAMATE_STATEMENT_TIMEOUT_MS` | Timeout for predefined reports (default `30000`) |
| `TESLAMATE_QUERY_TIMEOUT_MS` | Timeout for `teslamate_run_sql` (default `5000`) |
| `TESLAMATE_CUSTOM_SQL_ROW_LIMIT` | Auto-LIMIT for ad-hoc SQL without LIMIT (default `1000`) |

## Tools

About **32** tools:

- **30 predefined reports** — same names as upstream teslamate-mcp (`get_battery_capacity_trend`, `get_charging_costs`, `search_drives`, …), loaded from `queries/*.sql` + `*.toml`
- `teslamate_get_database_schema` — table list or column detail
- `teslamate_run_sql` — ad-hoc `SELECT` / `WITH … SELECT` in a read-only transaction (always rolled back)

No write tools and no MCP Apps chart UIs in this port.

## Files

- `server.rb` — MCP tools and auth form
- `postgres_client.rb` — `pg` client, timeouts, schema cache
- `query_registry.rb` — SQL/TOML discovery, `%(name)s` → `$n` binding, SQL validation
- `queries/` — report definitions
