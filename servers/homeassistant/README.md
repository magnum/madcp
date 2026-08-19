# Home Assistant

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for [Home Assistant](https://www.home-assistant.io/), backed by
[`home-assistant-cli`](https://github.com/home-assistant-ecosystem/home-assistant-cli) (`hass-cli`).

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/homeassistant/mcp
```

Operator UI: `/servers/homeassistant/auth`

## Credentials

1. In HA: Profile → Long-Lived Access Tokens → create a token.
2. Set **HASS_SERVER** (e.g. `http://192.168.0.10:8123`) and **HASS_TOKEN**.
3. Paste them on `/servers/homeassistant/auth`, or put them in the host `/data/emcp/storage/.env`.

Optional: `HASS_INSECURE=true` for self-signed TLS. Writes need `HOMEASSISTANT_ALLOW_WRITE=true`.

## Environment

| Variable | Purpose |
| --- | --- |
| `HASS_SERVER` | Home Assistant base URL |
| `HASS_TOKEN` | Long-lived access token |
| `HASS_INSECURE` | Pass `--insecure` to hass-cli when `true` |
| `HASS_TIMEOUT` | CLI timeout seconds (default `30`) |
| `HASS_CLI_BIN` | Override binary path (default `hass-cli`) |
| `HOMEASSISTANT_ALLOW_WRITE` | Enable write tools |

## Tools

Read: config/info, state list/get/history, service list, device/area/entity list.  
Write (gated): service call, state edit, area create/delete, device assign, raw API.

## Files

- `server.rb` — MCP tools and auth form
- `homeassistant_client.rb` — thin `hass-cli` wrapper
