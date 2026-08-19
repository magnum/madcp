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
  /home/emcp/.config/basecamp \
  /home/emcp/.cache/basecamp \
  /home/emcp/.config/hey-cli \
  /home/emcp/.config/gws
chown -R emcp:emcp /app/data /app/logs /home/emcp/.config /home/emcp/.cache

exec gosu emcp "$@"
