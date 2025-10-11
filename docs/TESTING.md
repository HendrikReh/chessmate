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
