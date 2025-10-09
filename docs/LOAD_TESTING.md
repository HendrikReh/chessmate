# Load Testing Guide

## Goals
- Measure `/query` throughput and latency under sustained load.
- Validate Postgres pool sizing (`CHESSMATE_DB_POOL_SIZE`) and monitor queue depth.
- Capture baseline metrics before tuning.

## Prerequisites
- Docker services running (`docker compose up -d postgres qdrant redis`).
- API running (`dune exec services/api/chessmate_api.exe -- --port 8080`).
- Load tool installed: [oha](https://github.com/hatoo/oha) or [vegeta](https://github.com/tsenart/vegeta).

## Quickstart
```sh
eval "$(opam env --set-switch)"
./scripts/load_test.sh
```
Default settings: `DURATION=60s`, `CONCURRENCY=50`, POST payload stored in `scripts/fixtures/load_test_query.json`.

Override environment variables as needed:
```sh
CONCURRENCY=80 DURATION=120s TOOL=vegeta ./scripts/load_test.sh
```

## Metrics & Observability
Immediately after the run, the script prints:
- `/metrics` output (focus on `db_pool_capacity`, `db_pool_in_use`, `db_pool_available`, `db_pool_waiting`).
- `docker stats` snapshot for Postgres/Qdrant/Redis.

Consider capturing `oha`/`vegeta` output for p50/p95 latency, requests/sec, and error rate. Persist results in an internal spreadsheet or this doc as needed.

## Tuning Tips
- Increase `CHESSMATE_DB_POOL_SIZE` when `db_pool_waiting` stays non-zero and CPU headroom remains.
- Watch Postgres CPU and connection limits when raising the pool size.
- If OpenAI/Qdrant become bottlenecks, adjust their respective concurrency/timeouts accordingly.

## Next Steps
- Automate load tests in a CI/CD pipeline (manual trigger) once the baseline is stable.
- Expand the script to test multiple endpoints or payload variations as features evolve.
