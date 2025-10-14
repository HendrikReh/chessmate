# Manual Test Plan (2025-10-xx)

Validates core Chessmate functionality: ingest, embedding, hybrid query, agent scoring, caching, and fallback behaviour. Use together with the [Developer Handbook](DEVELOPER.md) and [Operations Playbook](OPERATIONS.md).

---

## 1. Environment Prep
```sh
cp .env.sample .env
source .env        # or export manually
docker compose up -d postgres qdrant redis
./scripts/migrate.sh
# optional seed
dune exec chessmate -- ingest test/fixtures/extended_sample_game.pgn
```
Ensure `CHESSMATE_TEST_DATABASE_URL` points to a role with `CREATEDB` for integration runs (`ALTER ROLE chess WITH CREATEDB;`).

---

## 2. Start Services
```sh
eval "$(opam env --set-switch)"
dune exec -- services/api/chessmate_api.exe --port 8080
```
Optional embedding worker:
```sh
OPENAI_API_KEY=dummy   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate   dune exec -- embedding_worker -- --workers 1 --poll-sleep 1.0 --exit-after-empty 3
```

---

## 3. Agent Query Checkpoint
```sh
AGENT_API_KEY=your-openai-key AGENT_REASONING_EFFORT=high CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Find queenside majority attacks in King's Indian"
```
Expectation: ~10s response, each result carries `agent_score`, `agent_explanation`, `agent_reasoning_effort`.

---

## 4. Telemetry Verification
Inspect API logs for `[agent-telemetry]` JSON entries with candidate counts, latency (ms), and token usage. Set `AGENT_COST_*` to surface USD estimates.

---

### 4a. Prometheus Label Escaping Check
This manual probe verifies that oddball request paths cannot break the `/metrics` endpoint.

1. **Pre-req**: API running locally (see §2). Use a fresh shell with `eval "$(opam env --set-switch)"`.
2. **Trigger a weird route**:
   ```sh
   curl -sS -o /dev/null -w "%{http_code}\n" -g "http://localhost:8080/metrics%22bad%5Cname"
   ```
   `curl` percent-encodes reserved characters, so the middleware records the literal `GET /metrics%22bad%5Cname`. A `404` status is normal—the router only exposes `/metrics`.
3. **Send a raw-path request** (to exercise true quotes/backslashes):
   ```sh
   printf 'GET /metrics"bad\\name HTTP/1.1\r\nHost: localhost:8080\r\n\r\n' | nc -N localhost 8080
   ```
   On GNU `nc`, use `-q 1` instead of `-N`. The server replies with `404` (only `/metrics` exists), but the middleware still records the literal path containing `"` and `\`.
4. **Inspect metrics output**:
   ```sh
   curl -s http://localhost:8080/metrics | grep 'api_request_total{route='
   ```
   Expect to see the route surfaced as `api_request_total{route="GET /metrics\"bad\\name"}` (note the escaped quote and backslash). If the line is missing or contains raw `"`/`\`, the escape helper regressed.

---

### 4b. Health Endpoint Snapshot

1. With the API running, fetch the structured health payload:
   ```sh
   curl -s http://localhost:8080/health | jq
   ```
   Expect `status: "ok"` under normal conditions. Required dependency failures return `status: "error"` and HTTP 503; optional failures surface as `"degraded"` (also 503) with details for triage.
2. If the embedding worker is running, repeat against its endpoint:
   ```sh
   curl -s "http://localhost:${CHESSMATE_WORKER_HEALTH_PORT:-8081}/health" | jq
   ```
   Confirm that the worker reports Postgres/Qdrant/OpenAI probes and mirrors the API schema.

---

### 4c. Hook Health Into Monitoring

1. **API probe**: point your HTTP monitor to `http://<host>:8080/health`. Treat any HTTP status ≠ 200 as an alert. Parse the JSON body for `status` and surface it as a primary metric (`ok`, `degraded`, `error`) plus per-check details for dashboards.
2. **Worker probe**: target `http://<host>:${CHESSMATE_WORKER_HEALTH_PORT:-8081}/health`. If you run multiple workers on the same host, assign unique ports via `CHESSMATE_WORKER_HEALTH_PORT` and configure the monitor per instance.
3. **Sample curl** (useful for local smoke tests or scripted checks):
   ```sh
   for port in 8080 "${CHESSMATE_WORKER_HEALTH_PORT:-8081}"; do
     echo "# probing ${port}"
     curl -sf "http://localhost:${port}/health" \
       | jq -r '.status as $s | ["health_status=" + $s] + (.checks[] | .name + ":" + .status) | @tsv'
   done
   ```
   This prints the overall status followed by each check’s outcome (e.g., `postgres:ok`). Integrate the command (or equivalent agent) into your monitoring stack to capture both the aggregate health and individual dependency signals.

---

## 5. Redis Cache Behaviour
Repeat the query. On second run, logs should show cache hits (no fresh GPT-5 call). Optional: `redis-cli --scan --pattern 'chessmate:agent:*'` to inspect stored keys.

---

## 6. Fallback Scenario
Disable the agent:
```sh
unset AGENT_API_KEY
CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Explain thematic rook sacrifices"
```
Result should use heuristic scores only, with a warning indicating the agent is disabled.

---

## 7. Cache Maintenance
```sh
redis-cli --scan --pattern 'chessmate:agent:*' | xargs -r redis-cli del
```
Re-run the query; verify a new `[agent-telemetry]` entry appears (cache repopulated). Use loop variant for large datasets or change `AGENT_CACHE_REDIS_NAMESPACE` temporarily when migrating prompts.

---

## 8. Regression Suite
```sh
dune fmt
dune build
dune runtest
```
CI runs `dune build @fmt`; keep results green.

Target integration cases when needed:
```sh
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
dune exec test/test_main.exe -- test integration
```
Vector hits are stubbed; only Postgres connectivity/`CREATEDB` is required.

---

## 9. Clean-up
```sh
docker compose down
rm -rf data/postgres data/qdrant data/redis
```
Useful when resetting local state (follow with integration test to confirm).

---

## 10. Optional Benchmarks
- **Bulk ingest**: `CHESSMATE_INGEST_CONCURRENCY=1 time chessmate ingest /tmp/combined_twic.pgn`, then increase concurrency and compare timings. Watch Postgres load via `pg_stat_activity`.
- **Load test**: `TOOL=oha DURATION=60s CONCURRENCY=50 ./scripts/load_test.sh` (see [LOAD_TESTING.md](LOAD_TESTING.md)). Review p95 latency, throughput, `db_pool_wait_ratio`, and rate limiter counters.

Document results, warnings, or follow-up actions in PR descriptions or the issue tracker.
