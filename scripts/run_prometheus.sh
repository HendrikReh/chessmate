#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH=${CONFIG_PATH:-prometheus/prometheus.yml}
PROM_VERSION=${PROM_VERSION:-v2.51.2}
CONTAINER_NAME=${CONTAINER_NAME:-prometheus}
PORT=${PORT:-9090}

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Prometheus config not found: $CONFIG_PATH" >&2
  echo "Copy prometheus/prometheus.yml.example to $CONFIG_PATH and adjust targets." >&2
  exit 1
fi

docker run --rm \
  --name "$CONTAINER_NAME" \
  -p "$PORT:9090" \
  -v "$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$(basename "$CONFIG_PATH"):/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:"$PROM_VERSION"
