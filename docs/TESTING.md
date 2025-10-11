# Manual Test Plan – Milestone 5

This checklist validates the Milestone 5 checkpoints: agent-ranked search, telemetry, caching, and fallback behaviour.

> For setup prerequisites reference the [Developer Handbook](DEVELOPER.md); for runtime commands consult the [Operations Playbook](OPERATIONS.md); for debugging steps see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 1. Environment Prep
- Copy configuration: `cp .env.sample .env` (edit credentials as needed).
- Export env vars in a new shell (`set -a && source .env` or manual exports).
- Launch backing services: `docker compose up -d postgres qdrant redis`.
- Run migrations/seed data:
  ```sh
  ./scripts/migrate.sh
  chessmate ingest test/fixtures/extended_sample_game.pgn  # optional but recommended
  ```
- For integration tests that exercise ingestion end-to-end, set `CHESSMATE_TEST_DATABASE_URL`
  to a Postgres connection string owned by a role with `CREATEDB`. With the Docker Compose stack
  run `docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"` once to
  grant the permission. The harness creates and drops disposable databases; if the connection
  fails, the suite aborts immediately and prints the database error.

## 2. Start Application Components
- Bootstrap opam switch in each terminal: `eval $(opam env --set-switch)`.
- Start the query API (leave running to observe logs):
  ```sh
  dune exec -- services/api/chessmate_api.exe --port 8080
  ```
- Optionally start the embedding worker (not required for functional tests but useful for end-to-end validation):
  ```sh
  OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
    dune exec embedding_worker -- --workers 1 --poll-sleep 1.0 --exit-after-empty 3
  ```
  The `--exit-after-empty 3` flag exercises the new auto-shutdown path—after three empty polls the worker exits cleanly and prints the run summary without needing Ctrl-C.

## 3. Agent Query Checkpoint
- In a separate shell, run:
  ```sh
  AGENT_API_KEY=your-openai-key \
  AGENT_REASONING_EFFORT=high \
  CHESSMATE_API_URL=http://localhost:8080 \
  dune exec chessmate -- query "Find queenside majority attacks in King's Indian"
  ```
- Expectation:
  - Response returns within ~10 s.
  - Each result includes `agent_score`, `agent_explanation`, `agent_reasoning_effort`.
  - CLI summary references the explanations/themes supplied by GPT-5.

## 4. Telemetry Verification
- In the API shell, confirm `[agent-telemetry]` JSON log entries include:
  - `candidate_count`, `evaluated`, `reasoning_effort`, `latency_ms`.
  - `tokens` object (input/output/reasoning).
  - `cost` fields when `AGENT_COST_*` env vars are configured.

## 5. Redis Cache Behaviour
- Rerun the same query from step 3.
- Observe API log noting cache hit (e.g., `agent cache enabled via redis...` followed by `Agent evaluated...` only on first run).
- Optionally inspect Redis directly:
  ```sh
  redis-cli --scan --pattern 'chessmate:agent:*'
  ```
  You should see keys after the first query and no new `[agent-telemetry]` lines on cache hits.

## 6. Fallback Scenario
- Disable the agent by unsetting `AGENT_API_KEY` (or restart API without the variable):
  ```sh
  unset AGENT_API_KEY
  CHESSMATE_API_URL=http://localhost:8080 dune exec chessmate -- query "Explain thematic rook sacrifices"
  ```
- Expectation: response completes using heuristic scores, includes a warning about the agent being disabled, and no `agent_score` fields are emitted.

## 7. Cache Maintenance Procedure
- Simulate prompt/schema change by flushing namespace-specific keys:
  ```sh
  redis-cli --scan --pattern 'chessmate:agent:*' | xargs -r redis-cli del
  ```
- Alternatively, test the loop variant for large keysets:
  ```sh
  redis-cli --scan --pattern 'chessmate:agent:*' \
    | while read -r key; do redis-cli del "$key" >/dev/null; done
  ```
- Issue the Milestone 5 query again and verify a new `[agent-telemetry]` entry appears (proving cache eviction succeeded).

## 8. Regression Sweep
- Run automated suite for completeness:
  ```sh
  dune build && dune test
  ```
- Formatting check is part of CI; run `dune fmt` locally before committing (equivalent to `dune build @fmt`). The repo uses `.ocamlformat` profile `conventional`/version `0.27.0`.
- Target just the integration cases when you need a quick ingest/query sanity check:
  ```sh
  export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
  eval "$(opam env --set-switch)"
  psql "$CHESSMATE_TEST_DATABASE_URL" -c '\conninfo'               # optional: verify credentials
  dune exec test/test_main.exe -- list                             # optional: inspect suites
  dune exec test/test_main.exe -- test integration                 # run the integration group
  ```
  These tests stub vector hits—no Qdrant or OpenAI credentials required—but they expect the
  database URL above to work and to grant `CREATEDB`.
- Optional: execute `redis-cli FLUSHDB` (only if Redis is dedicated) to confirm the application recovers cleanly on next query.

## 9. Clean-up
- `docker compose down` to stop services.
- Remove `data/postgres`, `data/qdrant`, `data/redis` if a reset is desired.
- Clear environment variables or close terminals.

## 10. Benchmark Large PGN Ingest (Optional)
- Assemble a sizeable corpus (several TWIC issues or another bulk PGN set). For example:
  ```sh
  cat data/games/twic*.pgn > /tmp/combined_twic.pgn
  ```
- Run a sequential baseline to capture wall-clock time:
  ```sh
  CHESSMATE_INGEST_CONCURRENCY=1 \
    time chessmate ingest /tmp/combined_twic.pgn
  ```
- Repeat with higher concurrency (default 4, try 8/16) and record timings. Monitor Postgres load (e.g. `pg_stat_activity`) to ensure the database keeps up.
- Compare results to validate throughput gains. Pick a concurrency level that balances CPU usage and database throughput for your environment.

## 11. Load Test Validation (Optional)
- Ensure the API is running on `localhost:8080` (default configuration from step 2) and that Qdrant/Postgres are warmed up with sample data.
- Install a load generator (`oha` preferred, `vegeta` supported) and verify it’s on your `PATH`.
- Execute the harness for a one-minute burst at 50 concurrent clients:
  ```sh
  TOOL=oha DURATION=60s CONCURRENCY=50 TARGET_URL=http://localhost:8080/query \
    scripts/load_test.sh
  ```
- Review the summary printed by the tool (p50/p95 latency, throughput) and the trailing `/metrics` snapshot. Healthy runs show `db_pool_wait_ratio` near zero and `db_pool_in_use` well below `db_pool_capacity`.
- Capture `docker stats` output (emitted by the script) to confirm Postgres and Qdrant stay within acceptable CPU/memory bounds.
