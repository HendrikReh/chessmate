#!/usr/bin/env bash
set -euo pipefail

warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
info() { printf '\033[36m[info]\033[0m %s\n' "$*"; }
error() { printf '\033[31m[fail]\033[0m %s\n' "$*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Missing required command: $1"
    return 1
  fi
}

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="$ROOT_DIR/.env"
ENV_SAMPLE="$ROOT_DIR/.env.sample"
OPAM_SWITCH_DIR="$ROOT_DIR/_opam"
OPAM_SWITCH_NAME="$(opam switch show 2>/dev/null || echo "chessmate-bootstrap")"
DEFAULT_DATABASE_URL="postgres://chess:chess@localhost:5433/chessmate"
MIGRATE_SCRIPT="$ROOT_DIR/scripts/migrate.sh"

main() {
  info "Validating prerequisites"
  require_cmd opam
  require_cmd dune
  require_cmd docker
  require_cmd docker-compose || require_cmd "docker compose"
  require_cmd psql || warn "psql not found; migrate.sh will fail if DATABASE_URL is unreachable"

  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "$ENV_SAMPLE" ]]; then
      info "Creating .env from .env.sample"
      cp "$ENV_SAMPLE" "$ENV_FILE"
    else
      warn ".env.sample missing – skipping .env creation"
    fi
  else
    info ".env already present – leaving it untouched"
  fi

  if [[ ! -d "$OPAM_SWITCH_DIR" ]]; then
    info "Creating opam switch (5.1.0)"
    opam switch create . 5.1.0
  else
    info "opam switch directory already exists"
  fi

  info "Loading opam environment"
  eval "$(opam env --set-switch)"

  info "Installing OCaml dependencies"
  opam install . --deps-only --with-test --yes

  info "Starting Docker services (postgres, qdrant, redis)"
  if command -v docker compose >/dev/null 2>&1; then
    docker compose up -d postgres qdrant redis
  else
    docker-compose up -d postgres qdrant redis
  fi

  if [[ -x "$MIGRATE_SCRIPT" ]]; then
    info "Running database migrations"
    DATABASE_URL="${DATABASE_URL:-$DEFAULT_DATABASE_URL}" "$MIGRATE_SCRIPT"
  else
    warn "Migration script missing or not executable: $MIGRATE_SCRIPT"
  fi

  info "Building workspace"
  dune build

  info "Running test suite"
  dune runtest

  info "Bootstrap complete"
}

main "$@"
