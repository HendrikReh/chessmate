#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: embedding_metrics.sh [--interval seconds] [--log path]

Summarise embedding queue status, recent throughput, and ETA for draining pending jobs.
Provide DATABASE_URL in the environment. When --interval is set, the script loops and
reports every N seconds. When --log is supplied, append human-readable snapshots to the
log file (while still printing to stdout).
USAGE
}

interval=""
log_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      shift
      interval="${1:-}"
      [[ -z "$interval" ]] && { echo "Missing value for --interval" >&2; exit 1; }
      if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo "--interval expects an integer number of seconds" >&2
        exit 1
      fi
      shift
      ;;
    --log)
      shift
      log_file="${1:-}"
      [[ -z "$log_file" ]] && { echo "Missing value for --log" >&2; exit 1; }
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

: "${DATABASE_URL:?DATABASE_URL must be set}"

psql_base=(psql --no-psqlrc -X -q -t -A --dbname "$DATABASE_URL")

calc_rate() {
  local completed=$1
  local minutes=$2
  if [[ "$minutes" -eq 0 ]]; then
    printf "0"
    return
  fi
  if [[ -z "$completed" || "$completed" -eq 0 ]]; then
    printf "0"
    return
  fi
  awk -v c="${completed}" -v m="${minutes}" 'BEGIN { printf "%.2f", c / m }'
}

summarise_once() {
  local now status_rows pending completed failed in_progress total

  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # Fetch queue snapshot with totals per status.
  status_rows=$("${psql_base[@]}" -c "WITH totals AS (SELECT status, COUNT(*) AS c FROM embedding_jobs GROUP BY status) SELECT status, c FROM totals UNION ALL SELECT 'TOTAL', SUM(c) FROM totals ORDER BY status;")

  pending=0
  completed=0
  failed=0
  in_progress=0
  total=0

  while IFS='|' read -r status count; do
    status=$(echo "$status" | xargs)
    count=$(echo "$count" | xargs)
    [[ -z "$status" ]] && continue
    case "$status" in
      completed) completed=$count ;;
      failed) failed=$count ;;
      in_progress) in_progress=$count ;;
      pending) pending=$count ;;
      TOTAL) total=$count ;;
    esac
  done <<< "$status_rows"

  # Recent throughput (5/15/60 minutes).
  local throughput_sql
  throughput_sql=$(cat <<'SQL'
SELECT
  COUNT(*) FILTER (WHERE completed_at >= NOW() - INTERVAL '5 minutes') AS c5,
  COUNT(*) FILTER (WHERE completed_at >= NOW() - INTERVAL '15 minutes') AS c15,
  COUNT(*) FILTER (WHERE completed_at >= NOW() - INTERVAL '60 minutes') AS c60
FROM embedding_jobs
WHERE status = 'completed';
SQL
)

  local throughput_res
  if throughput_res=$("${psql_base[@]}" -c "$throughput_sql"); then
    IFS='|' read -r completed_5 completed_15 completed_60 <<<"$throughput_res"
  else
    echo "Failed to fetch throughput stats" >&2
    completed_5=0
    completed_15=0
    completed_60=0
  fi
  completed_5=$(echo "$completed_5" | xargs)
  completed_15=$(echo "$completed_15" | xargs)
  completed_60=$(echo "$completed_60" | xargs)

  local rate_5 rate_15 rate_60 eta_minutes eta_hours
  rate_5=$(calc_rate "${completed_5:-0}" 5)
  rate_15=$(calc_rate "${completed_15:-0}" 15)
  rate_60=$(calc_rate "${completed_60:-0}" 60)

  if [[ "${rate_15}" == "0" ]]; then
    eta_minutes="n/a"
    eta_hours="n/a"
  else
    eta_minutes=$(awk -v p="${pending:-0}" -v r="${rate_15}" 'BEGIN { if (r == 0) { print "n/a" } else { printf "%.0f", p / r } }')
    if [[ "$eta_minutes" == "n/a" ]]; then
      eta_hours="n/a"
    else
      eta_hours=$(awk -v m="${eta_minutes}" 'BEGIN { printf "%.1f", m / 60 }')
    fi
  fi

  cat <<EOF
[${now}] embedding jobs snapshot
  total        : ${total}
  pending      : ${pending}
  in_progress  : ${in_progress}
  completed    : ${completed}
  failed       : ${failed}
  throughput/min (5m | 15m | 60m): ${rate_5} | ${rate_15} | ${rate_60}
  pending ETA  : ${eta_minutes} minutes (~${eta_hours} hours) based on 15m rate
EOF
}

while true; do
  output=$(summarise_once)
  echo "$output"
  if [[ -n "$log_file" ]]; then
    mkdir -p "$(dirname "$log_file")"
    echo "$output" >>"$log_file"
    echo >>"$log_file"
  fi
  if [[ -z "$interval" ]]; then
    break
  fi
  sleep "$interval"
done
