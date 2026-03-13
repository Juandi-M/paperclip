#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

INSTANCE_DIR="${HOME}/.paperclip/instances/default"
INSTANCE_DB_DIR="${INSTANCE_DIR}/db"
PORT="${PORT:-3100}"

echo "Starting nuclear sync..."
echo "- repo: $ROOT_DIR"
echo "- target branch: master"
echo "- upstream target: origin/master"
echo "- instance dir to delete: $INSTANCE_DIR"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Not inside a git repository." >&2
  exit 1
fi

echo
echo "1) Fetching remotes..."
git fetch origin --prune
if git remote get-url fork >/dev/null 2>&1; then
  git fetch fork --prune
fi

echo
echo "2) Resetting local master to origin/master..."
git checkout master
git reset --hard origin/master

echo
echo "3) Cleaning untracked files (non-ignored only)..."
git clean -fd

if git remote get-url fork >/dev/null 2>&1; then
  echo
  echo "4) Forcing fork/master to match origin/master..."
  git push fork refs/remotes/origin/master:refs/heads/master --force
fi

echo
echo "5) Stopping local Paperclip processes touching this instance..."

if command -v lsof >/dev/null 2>&1; then
  PORT_PIDS="$(lsof -ti tcp:${PORT} 2>/dev/null || true)"
  if [ -n "${PORT_PIDS}" ]; then
    echo "  - killing port ${PORT} PIDs: ${PORT_PIDS}"
    kill ${PORT_PIDS} 2>/dev/null || true
    sleep 1
  fi
fi

pkill -f "scripts/dev-runner.mjs" 2>/dev/null || true
pkill -f "tsx watch" 2>/dev/null || true

if [ -d "$INSTANCE_DIR" ] && command -v lsof >/dev/null 2>&1; then
  HOLDER_PIDS="$(lsof +D "$INSTANCE_DIR" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)"
  if [ -n "${HOLDER_PIDS}" ]; then
    echo "  - killing instance holder PIDs: ${HOLDER_PIDS}"
    kill ${HOLDER_PIDS} 2>/dev/null || true
    sleep 1
  fi
fi

echo
echo "6) Deleting embedded Paperclip instance..."
rm -rf "$INSTANCE_DIR"

if [ -d "$INSTANCE_DB_DIR" ]; then
  echo "Failed to remove instance DB at $INSTANCE_DB_DIR" >&2
  exit 1
fi

echo
echo "Done."
echo "- master now matches origin/master"
if git remote get-url fork >/dev/null 2>&1; then
  echo "- fork/master now matches origin/master"
fi
echo "- local Paperclip instance deleted"
echo
echo "Next clean boot:"
echo "  ./one-click.sh --fresh"
