#!/usr/bin/env bash
set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

HOST=${HOST:-localhost}
PORT=${PORT:-8080}
PATHNAME=${PATHNAME:-/metrics}
EXPECTED=${EXPECTED:-Prometheus text format}

URL="http://${HOST}:${PORT}${PATHNAME}"

echo "Checking ${URL}" >&2
status=$(curl -s -o /tmp/metrics.$$ -w "%{http_code}" "$URL" || true)
if [[ "$status" != "200" ]]; then
  echo "Non-200 status: ${status}" >&2
  exit 2
fi

if ! head -n 1 /tmp/metrics.$$ | grep -q "$EXPECTED"; then
  echo "Unexpected metrics banner" >&2
  head -n 5 /tmp/metrics.$$ >&2
  exit 3
fi

echo "Metrics endpoint healthy" >&2
rm -f /tmp/metrics.$$
