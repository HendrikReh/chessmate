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

if ! command -v "$TOOL" >/dev/null 2>&1; then
  echo "$TOOL not found on PATH" >&2
  exit 1
fi

case "$TOOL" in
  oha)
    "$TOOL" \
      --no-tui \
      --duration "$DURATION" \
      --connections "$CONCURRENCY" \
      --method POST \
      --header 'Content-Type: application/json' \
      --body "@$PAYLOAD" \
      "$TARGET_URL"
    ;;
  vegeta)
    echo "POST $TARGET_URL" \
     | echo "$(cat)" "$(jq -c . <"$PAYLOAD")" \
     | vegeta attack -rate=0 -duration="$DURATION" -workers="$CONCURRENCY" \
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
  docker stats --no-stream postgres qdrant redis || true
fi
