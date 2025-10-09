#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: prune_pending_jobs.sh [batch_size]

Mark pending embedding jobs whose positions already have a vector_id as completed.
Requires DATABASE_URL in the environment. Optionally pass a batch size (default 1000)
so you can prune incrementally without long-running transactions.
USAGE
}

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  usage
  exit 0
fi

batch_size="${1:-1000}"
if ! [[ "$batch_size" =~ ^[0-9]+$ && "$batch_size" -gt 0 ]]; then
  echo "Batch size must be a positive integer" >&2
  exit 1
fi

: "${DATABASE_URL:?DATABASE_URL must be set}"

sql=$(cat <<SQL
WITH candidates AS (
  SELECT ej.id
  FROM embedding_jobs AS ej
  JOIN positions AS p ON p.id = ej.position_id
  WHERE ej.status = 'pending'
    AND p.vector_id IS NOT NULL
  LIMIT ${batch_size}
), updated AS (
  UPDATE embedding_jobs AS ej
  SET status = 'completed',
      completed_at = NOW(),
      last_error = NULL
  FROM candidates
  WHERE ej.id = candidates.id
  RETURNING ej.id
)
SELECT COUNT(*) FROM updated;
SQL
)

updated=$(psql --no-psqlrc -X -q -t -A --dbname "$DATABASE_URL" -c "$sql")
updated=$(echo "$updated" | xargs)

echo "Marked ${updated:-0} pending jobs as completed."
