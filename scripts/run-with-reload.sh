#!/bin/sh
# Run MADCP and restart the Ruby process when:
#   - data/restart.txt is touched, or
#   - MADCP_AUTO_RELOAD=1 and a .rb/.erb under watched paths changes
#
# Usage (Docker override / local):
#   ./scripts/run-with-reload.sh
#   touch data/restart.txt

set -eu

ROOT="${MADCP_ROOT:-/app}"
cd "$ROOT"

MARKER="${MADCP_RESTART_MARKER:-$ROOT/data/restart.txt}"
AUTO_RELOAD="${MADCP_AUTO_RELOAD:-0}"
WATCH_PATHS="${MADCP_WATCH_PATHS:-$ROOT/servers $ROOT/lib $ROOT/views}"
POLL_SECONDS="${MADCP_RELOAD_POLL_SECONDS:-1}"

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"

file_mtime() {
  path=$1
  if stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
  else
    stat -f %m "$path"
  fi
}

sources_stamp() {
  # shellcheck disable=SC2086
  find $WATCH_PATHS -type f \( -name '*.rb' -o -name '*.erb' \) -printf '%T@\n' 2>/dev/null \
    | sort -n \
    | tail -1
}

marker_mtime=$(file_mtime "$MARKER")
sources_mtime=$(sources_stamp || true)
server_pid=""

start_server() {
  echo "[madcp] starting server"
  bundle exec ruby server.rb &
  server_pid=$!
}

stop_server() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    echo "[madcp] stopping server pid=$server_pid"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}

trap 'stop_server; exit 0' INT TERM

start_server

while true; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid" || status=$?
    echo "[madcp] server exited unexpectedly (status=${status:-0})"
    exit "${status:-1}"
  fi

  sleep "$POLL_SECONDS"

  now_marker=$(file_mtime "$MARKER")
  if [ "$now_marker" != "$marker_mtime" ]; then
    marker_mtime=$now_marker
    echo "[madcp] restart marker changed ($MARKER)"
    stop_server
    start_server
    sources_mtime=$(sources_stamp || true)
    continue
  fi

  case "$AUTO_RELOAD" in
    1|true|TRUE|yes|YES|on|ON)
      now_sources=$(sources_stamp || true)
      if [ -n "${now_sources:-}" ] && [ "${now_sources}" != "${sources_mtime:-}" ]; then
        sources_mtime=$now_sources
        echo "[madcp] source change detected; reloading"
        stop_server
        start_server
      fi
      ;;
  esac
done
