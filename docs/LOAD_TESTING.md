# Load Testing Guide

Evaluate Chessmate’s `/query` path under sustained load. Use this guide when validating infrastructure changes, tuning connection pools, or establishing performance baselines.

> Summary of goals: measure throughput/latency, observe resource usage (Postgres/Qdrant/Redis), and confirm the rate limiter/circuit breakers behave sensibly under pressure.

---

## 1. Prerequisites

| Requirement | Notes |
| --- | --- |
| Services running | `docker compose up -d postgres qdrant redis` (script auto-detects the resulting `chessmate-*-1` container names) |
| API listening | `eval "$(opam env --set-switch)" && dune exec -- services/api/chessmate_api.exe --port 8080` (restart before each run to reset `/metrics`) |
| Data seeded | Ingest a representative PGN corpus before testing |
| Load tool | [oha](https://github.com/hatoo/oha) (default) or [vegeta](https://github.com/tsenart/vegeta) |
| opam env | Run `eval "$(opam env --set-switch)"` so `dune` and scripts resolve |

Optional: ensure rate limits (`CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE`) are set high enough for the test window or monitor how often 429s appear.

---

## 2. Quick Start (Scripted)

```sh
eval "$(opam env --set-switch)"
DURATION=60s CONCURRENCY=50 TOOL=oha ./scripts/load_test.sh
```

Defaults:
- `DURATION=60s`
- `CONCURRENCY=50`
- `TARGET_URL=http://localhost:8080/query`
- Payload located at `scripts/fixtures/load_test_query.json`
- Tool: `oha`

Override env vars per run:
```sh
CONCURRENCY=80 DURATION=120s TOOL=vegeta TARGET_URL=http://localhost:8080/query   ./scripts/load_test.sh
```

The wrapper now:
1. Detects whether your `oha` build supports long flags (`--duration`, `--connections`) or only the legacy short variants (`-z`, `-c`) and adapts automatically.
2. Minifies the payload once (using `jq -c` when available) and sends the JSON body instead of the literal `@path` string that previously triggered `400` responses.
3. Pulls container IDs via `docker compose ps -q`, so Docker Desktop names (e.g., `chessmate-postgres-1`) appear in the stats snapshot without changes.

After each run the script prints:
1. Load tool summary (req/s, p50/p95 latency, error counts).
2. `/metrics` snapshot (DB pool gauges, rate limiter counters, etc.).
3. `docker stats` snapshot for Postgres, Qdrant, Redis.

Store results (latency, throughput, error rate, metrics snapshot) in an internal log or spreadsheet to track trends over time.

---

## 3. Manual Invocation (oha example)

```sh
PAYLOAD=$(jq -c . scripts/fixtures/load_test_query.json)
oha --duration 60s --connections 50 --method POST \
    --header 'Content-Type: application/json' \
    --body "$PAYLOAD" \
    http://localhost:8080/query
```

For vegeta:
```sh
echo "POST http://localhost:8080/query" \
  | vegeta attack -body scripts/fixtures/load_test_query.json \
      -header "Content-Type: application/json" \
      -duration=60s -rate=0 -max-workers=50 \
  | vegeta report
```

### 3.1 Agent Disabled Baseline

Run the API without GPT-5 to measure raw storage/vector performance:

```sh
PAYLOAD=$(jq -c . scripts/fixtures/load_test_query.json)
AGENT_API_KEY="" \
  oha --duration 60s --concurrency 50 \
      --header 'Content-Type: application/json' \
      --body "$PAYLOAD" \
      http://localhost:8080/query
```

Expect CPU-bound behaviour on Postgres/Qdrant, minimal variance in latency, and the absence of `[agent]` logs. Record the p95 latency/throughput pair as the lower bound for user-visible queries.

### 3.2 Agent Enabled Scenario

Repeat the run with GPT-5 enabled to capture end-to-end latency including re-ranking:

```sh
PAYLOAD=$(jq -c . scripts/fixtures/load_test_query.json)
AGENT_API_KEY=sk-real-key \
  oha --duration 60s --concurrency 30 \
      --header 'Content-Type: application/json' \
      --body "$PAYLOAD" \
      http://localhost:8080/query
```

Monitor `[agent-telemetry]` logs for token usage and latency, and compare throughput against the baseline. If variance is too high, reduce concurrency or provision more agent capacity before production rollout.

---

## 3.3 Interpreting Results

- **Status codes**: Expect `[200]` in the `oha` summary. If you see `[400]`, verify the request body is JSON (avoid `--body @file` with older `oha` releases).
- **Deadline aborts**: `oha` counts unfinished requests as `aborted due to deadline` when the timer elapses. Increase `DURATION` if you need a clean exit; the queries still completed.
- **Metrics alignment**: Restart `chessmate_api.exe` before each run so `api_request_total` and latency histograms represent the current benchmark window.
- **Resource focus**: Qdrant should dominate CPU usage for hybrid queries; Postgres and Redis remain lightly loaded unless ingest or caching tests run simultaneously.
- **Baseline targets**: With the canonical payload and GPT-5 disabled, a modern laptop should see ~500 req/s, median latency around 110 ms, and p95 around 180 ms. Record your numbers for regression tracking.

---

## 4. What to Watch

| Metric/Signal | Healthy Behaviour | Action if Degraded |
| --- | --- | --- |
| `db_pool_waiting` | Near zero | Increase `CHESSMATE_DB_POOL_SIZE` (watch CPU) |
| `db_pool_in_use` vs capacity | Well below capacity | If saturated, scale Postgres pool or optimise queries |
| Rate limiter counters (`api_rate_limited_total`) | Zero or expected level | If rising unintentionally, raise quota or reduce load |
| `/metrics` agent timeout counters (future) | Zero | Investigate GPT‑5 latency; consider fallbacks |
| `docker stats` CPU/memory | Within resource budget | Increase resources or lower concurrency |
| HTTP errors (5xx) | None | Inspect API logs, Postgres, Qdrant |

Also review CLI health logs (`[health] ...`) during the run to ensure dependencies remain available.

---

## 5. Common Tuning Steps

1. **Postgres pool** – Increase `CHESSMATE_DB_POOL_SIZE` incrementally (5–10 connections at a time). Monitor `db_pool_waiting`, CPU, and connection limits.
2. **Rate limiter** – Increase `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` during benchmarking or track how quickly 429s appear.
3. **Embedding/Qdrant** – If queries see slow vector responses, confirm Qdrant resources (CPU/IO) and adjust worker/API concurrency.
4. **OpenAI agent** – Disable GPT‑5 re-ranking during raw latency benchmarks if it introduces uncontrolled variance.

Document parameter changes alongside results so future tests can reproduce conditions.

---

## 6. Next Steps

- Automate the script in CI (manual trigger) to produce periodic baselines.
- Extend the harness with multiple payloads (different queries/opening filters).
- Add alerting thresholds based on measured latency/error rate so the rate limiter and upcoming circuit breaker don’t hide issues.
- Capture the `oha` summary, `/metrics`, and `docker stats` table in PRs that touch performance-sensitive paths so reviewers can track deltas over time.

Keeping a consistent load-test regimen helps ensure Chessmate remains responsive as data volume and user traffic grow.
