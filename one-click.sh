#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

FRESH_DB=0
if [ "${1:-}" = "--fresh" ]; then
  FRESH_DB=1
  shift
fi

if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm is required but was not found in PATH." >&2
  exit 1
fi

# Force local embedded Postgres mode unless the operator explicitly overrides it.
unset DATABASE_URL

# Keep local authenticated dev bootable without requiring a hand-managed secret.
export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-paperclip-local-dev-secret}"
export PAPERCLIP_AGENT_JWT_SECRET="${PAPERCLIP_AGENT_JWT_SECRET:-$BETTER_AUTH_SECRET}"
export PAPERCLIP_MIGRATION_PROMPT=never
export ENABLE_CLAUDEAI_MCP_SERVERS=false

EMBEDDED_DB_DIR="${HOME}/.paperclip/instances/default/db"

if [ "$FRESH_DB" -eq 1 ] && [ -d "$EMBEDDED_DB_DIR" ]; then
  echo "Removing embedded dev database at $EMBEDDED_DB_DIR"
  rm -rf "$EMBEDDED_DB_DIR"
fi

if [ ! -d node_modules ] || [ ! -x node_modules/.bin/cross-env ]; then
  echo "Installing dependencies with pnpm..."
  pnpm install
fi

echo "Preparing embedded database schema..."
pnpm db:migrate

echo "Starting Paperclip in local dev mode..."
echo "- DATABASE_URL: embedded Postgres"
echo "- BETTER_AUTH_SECRET: local default"
echo "- PAPERCLIP_AGENT_JWT_SECRET: configured"
echo "- migrations: pre-applied"
echo "- claude.ai MCP connectors: disabled"
if [ "$FRESH_DB" -eq 1 ]; then
  echo "- embedded DB: fresh reset"
else
  echo "- embedded DB: reusing existing data"
fi
echo "- URL: http://localhost:3100"

exec pnpm dev "$@"
