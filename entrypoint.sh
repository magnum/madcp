#!/bin/sh
set -e

mkdir -p \
  /app/data \
  /app/data/_oauth \
  /app/data/cli/basecamp \
  /app/data/cli/basecamp-cache \
  /app/data/cli/hey \
  /app/data/cli/gws \
  /app/logs \
  /home/madcp/.config/basecamp \
  /home/madcp/.cache/basecamp \
  /home/madcp/.config/hey-cli \
  /home/madcp/.config/gws
chown -R madcp:madcp /app/data /app/logs /home/madcp/.config /home/madcp/.cache

exec gosu madcp "$@"
