#!/usr/bin/env bash
# Pull latest changes, optionally edit .env, then rebuild and restart Docker Compose.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "==> Pulling latest changes"
git pull

echo
read -r -p "Edit .env with vi before restarting? [y/N] " answer
case "${answer}" in
  y|Y|yes|YES)
    if [[ ! -f .env ]]; then
      if [[ -f .env.example ]]; then
        echo "==> .env is missing; copying from .env.example"
        cp .env.example .env
      else
        echo "error: .env does not exist and .env.example was not found" >&2
        exit 1
      fi
    fi
    "${EDITOR:-vi}" .env
    ;;
  *)
    echo "==> Skipping .env edit"
    ;;
esac

echo
echo "==> Rebuilding and restarting containers"
docker compose up --build -d

echo
echo "==> Done"
docker compose ps
