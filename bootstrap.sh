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
HOOKS_DIR="$ROOT_DIR/.githooks"

run_with_retries() {
  local description="$1"
  shift
  local max_attempts="$1"
  shift

  local attempt=1
  local delay=1
  while (( attempt <= max_attempts )); do
    if "$@"; then
      return 0
    fi
    warn "${description} failed (attempt ${attempt}/${max_attempts})"
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
  error "${description} failed after ${max_attempts} attempts"
  return 1
}

wait_for_postgres() {
  if ! command -v pg_isready >/dev/null 2>&1; then
    warn "pg_isready not found; skipping postgres readiness check"
    return 0
  fi
  local url="${DATABASE_URL:-$DEFAULT_DATABASE_URL}"
  run_with_retries "postgres readiness" 6 pg_isready -d "$url"
}

wait_for_qdrant() {
  local base_url="${QDRANT_URL:-http://localhost:6333}"
  run_with_retries "qdrant readiness" 6 curl -fsS "$base_url/healthz"
}

wait_for_redis() {
  if ! command -v redis-cli >/dev/null 2>&1; then
    warn "redis-cli not found; skipping redis readiness check"
    return 0
  fi
  local redis_url="${REDIS_URL:-redis://localhost:6379}"
  run_with_retries "redis readiness" 6 redis-cli -u "$redis_url" ping >/dev/null
}

parse_args() {
  SKIP_TESTS=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --skip-tests)
      SKIP_TESTS=true
      shift
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
    esac
  done
}

main() {
  parse_args "$@"

  info "Validating prerequisites"
  require_cmd opam
  require_cmd dune
  require_cmd docker
  require_cmd docker-compose || require_cmd "docker compose"
  require_cmd psql || warn "psql not found; migrate.sh will fail if DATABASE_URL is unreachable"

  if [[ -d "$HOOKS_DIR" ]]; then
    info "Configuring git hooks path"
    git config core.hooksPath "$HOOKS_DIR"
  fi

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

  if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
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

  local compose_cmd
  if command -v docker compose >/dev/null 2>&1; then
    compose_cmd=(docker compose)
  else
    compose_cmd=(docker-compose)
  fi

  info "Starting Docker services (postgres, qdrant, redis)"
  run_with_retries "docker services startup" 5 "${compose_cmd[@]}" up -d postgres qdrant redis

  info "Waiting for service readiness"
  wait_for_postgres || exit 1
  wait_for_qdrant || exit 1
  wait_for_redis || exit 1

  if [[ -x "$MIGRATE_SCRIPT" ]]; then
    info "Running database migrations"
    DATABASE_URL="${DATABASE_URL:-$DEFAULT_DATABASE_URL}" "$MIGRATE_SCRIPT"
  else
    warn "Migration script missing or not executable: $MIGRATE_SCRIPT"
  fi

  info "Building workspace"
  dune build

  if [[ "$SKIP_TESTS" == true ]]; then
    info "Skipping test suite (--skip-tests flag provided)"
  else
    info "Running test suite"
    dune runtest
  fi

  info "Bootstrap complete"
}

main "$@"
