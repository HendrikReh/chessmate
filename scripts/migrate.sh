#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL environment variable must be set" >&2
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MIGRATIONS_DIR="$ROOT_DIR/scripts/migrations"

shopt -s nullglob
MIG_FILES=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

if [[ ${#MIG_FILES[@]} -eq 0 ]]; then
  echo "No migration files found in $MIGRATIONS_DIR" >&2
  exit 1
fi

for file in "${MIG_FILES[@]}"; do
  echo "Applying migration $(basename "$file")"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$file"
  echo "Applied $(basename "$file")"
  echo
done
