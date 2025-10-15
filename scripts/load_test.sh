#!/usr/bin/env bash
set -euo pipefail

DURATION=${DURATION:-60s}
CONCURRENCY=${CONCURRENCY:-50}
TARGET_URL=${TARGET_URL:-http://localhost:8080/query}
PAYLOAD=${PAYLOAD:-scripts/fixtures/load_test_query.json}
TOOL=${TOOL:-oha}

if [[ ! -f "$PAYLOAD" ]]; then
  echo "Payload file $PAYLOAD missing" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  REQUEST_BODY=$(jq -c . <"$PAYLOAD")
else
  REQUEST_BODY=$(tr '\n' ' ' <"$PAYLOAD" | tr -s ' ')
fi

if ! command -v "$TOOL" >/dev/null 2>&1; then
  echo "$TOOL not found on PATH" >&2
  exit 1
fi

case "$TOOL" in
  oha)
    if "$TOOL" --help 2>&1 | grep -q -- '--duration'; then
      "$TOOL" \
        --no-tui \
        --duration "$DURATION" \
        --connections "$CONCURRENCY" \
        --method POST \
        --header 'Content-Type: application/json' \
        --body "$REQUEST_BODY" \
        "$TARGET_URL"
    else
      "$TOOL" \
        --no-tui \
        -z "$DURATION" \
        -c "$CONCURRENCY" \
        -m POST \
        -H 'Content-Type: application/json' \
        -d "$REQUEST_BODY" \
        "$TARGET_URL"
    fi
    ;;
  vegeta)
    echo "POST $TARGET_URL" \
     | vegeta attack -rate=0 -duration="$DURATION" -workers="$CONCURRENCY" \
        -header "Content-Type: application/json" \
        -body "$PAYLOAD" \
     | vegeta report
    ;;
  *)
    echo "Unsupported TOOL=$TOOL" >&2
    exit 1
    ;;
 esac

if command -v curl >/dev/null 2>&1; then
  echo "--- /metrics ---"
  curl -s http://localhost:8080/metrics || true
fi

if command -v docker >/dev/null 2>&1; then
  echo "--- docker stats snapshot ---"
  docker_targets=()
  if docker compose version >/dev/null 2>&1; then
    while IFS= read -r id; do
      if [[ -n "$id" ]]; then
        docker_targets+=("$id")
      fi
    done < <(docker compose ps -q 2>/dev/null || true)
  elif command -v docker-compose >/dev/null 2>&1; then
    while IFS= read -r id; do
      if [[ -n "$id" ]]; then
        docker_targets+=("$id")
      fi
    done < <(docker-compose ps -q 2>/dev/null || true)
  fi
  if [[ ${#docker_targets[@]} -eq 0 ]]; then
    docker_targets=(postgres qdrant redis)
  fi
  docker stats --no-stream "${docker_targets[@]}" || true
fi
