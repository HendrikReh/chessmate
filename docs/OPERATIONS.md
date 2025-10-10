# Operations Playbook

> Pair this runbook with the [Developer Handbook](DEVELOPER.md), the manual suite in [TESTING.md](TESTING.md), and the failure guide in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Service Topology
- **postgres**: canonical PGN/metadata store, embedding job queue. Volume: `data/postgres`.
- **qdrant**: vector store for FEN embeddings (integration in progress—see notes below), exposed on 6333/6334. Volume: `data/qdrant`.
- **chessmate-api**: Opium HTTP service (prototype) for `/query`.
- **embedding-worker**: OCaml worker polling `embedding_jobs`; today it derives deterministic `vector_id`s and marks jobs complete, with live Qdrant writes scheduled as the next milestone.
- **redis**: shared cache for agent evaluations (persisted under `data/redis`).

## Bootstrapping Environment
Copy `.env.sample` to `.env`, adjust the values, and then export or `source` them before running commands.
Quick start: run `./bootstrap.sh` to automate the steps below; it is safe to re-run when dependencies change.
```sh
# set connection strings for local dev
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
export CHESSMATE_API_URL=http://localhost:8080
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres  # integration tests
# export CHESSMATE_OPENAPI_SPEC=/etc/chessmate/openapi.yaml                            # optional override for spec path

# start core services (first run pulls images)
docker compose up -d postgres qdrant redis

# apply migrations (idempotent)
./scripts/migrate.sh

# seed sample PGNs (optional) - respects CHESSMATE_MAX_PENDING_EMBEDDINGS
chessmate ingest test/fixtures/extended_sample_game.pgn
```
Cross-check the environment against the [Configuration Reference](DEVELOPER.md#configuration-reference); the services will refuse to boot if a required variable is missing.

> **First-time setup:** the Docker Compose postgres user (`chess`) does **not** ship with `CREATEDB`. Run:
> ```sh
> docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"
> ```
> This grants the permission required for the integration suite to create throwaway databases.

### Service Startup
- Query API (prototype): `dune exec services/api/chessmate_api.exe -- --port 8080`.
- Embedding worker: `OPENAI_API_KEY=... dune exec services/embedding_worker/embedding_worker.exe -- --workers N` (run multiple loops inside one process; increase `N` gradually when clearing backlogs).
- CLI queries: `dune exec chessmate -- query "find king's indian games"` (ensure the API is running in another shell).
- OpenAPI specification: `curl http://localhost:8080/openapi.yaml` (serve an alternate file by exporting `CHESSMATE_OPENAPI_SPEC`).
- Pool metrics: `curl http://localhost:8080/metrics` exposes `db_pool_*` gauges. Adjust the pool size via `CHESSMATE_DB_POOL_SIZE` (default 10) when tuning throughput.
- Queue metrics: `scripts/embedding_metrics.sh --interval 120 --log logs/embedding-metrics.log` keeps per-status counts, throughput, and ETA.
- Load testing: `DURATION=60s CONCURRENCY=50 ./scripts/load_test.sh` drives sustained `/query` traffic (requires `oha` or `vegeta`). Capture results and adjust `CHESSMATE_DB_POOL_SIZE` / service replicas as needed.
- Startup sanity check: both processes emit a `[...][config]` line summarising detected env vars (port, database URL presence, agent/Redis caches). If a variable shows as `missing`, correct it before continuing.
- High-volume ingest: adjust `CHESSMATE_INGEST_CONCURRENCY` (default 4) to balance CPU throughput vs. Postgres load when parsing large PGN dumps.
- GPT-5 agent (optional): set `AGENT_API_KEY` (and optionally `AGENT_MODEL`, `AGENT_REASONING_EFFORT`, `AGENT_VERBOSITY`, `AGENT_CACHE_REDIS_URL`) before calling `chessmate query` or starting the API to enable ranking/explanations. If Redis is unavailable, fall back to `AGENT_CACHE_CAPACITY` for the in-process cache.

### Integration Smoke Test
Use the built-in integration suite to verify ingestion, job processing, and hybrid search end-to-end. The runner creates and drops disposable databases, so the connection string supplied via `CHESSMATE_TEST_DATABASE_URL` must belong to a role with `CREATEDB`.

```sh
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
eval "$(opam env --set-switch)"
psql "$CHESSMATE_TEST_DATABASE_URL" -c '\conninfo'               # optional: verify credentials
dune exec test/test_main.exe -- list                 # optional: inspect suites
dune exec test/test_main.exe -- test integration     # run only the integration group
```

The tests stub Qdrant/OpenAI access, so the suite passes without those services. If the database cannot be reached, Alcotest fails immediately and prints the connection error.

## Runtime Management
- **Health checks**:
  - API: `GET /health`.
  - Postgres: `docker compose exec postgres pg_isready -U chess`.
  - Qdrant: `curl http://localhost:6333/healthz`.
- **Degraded mode**: when Qdrant is unavailable or `QDRANT_URL` is unset, the API logs `Vector search unavailable (...)` warnings and falls back to metadata-only ranking. This keeps queries responsive while you restore vector infrastructure.
- **Graceful shutdown**: send `SIGTERM`/`SIGINT` to the API (`pkill -TERM -f chessmate_api.exe`) or worker (`pkill -TERM -f embedding_worker.exe`). Both listeners stop accepting new work, finish in-flight jobs, and log a shutdown summary before exiting.
- **Logs**: `docker compose logs -f <service>`; ship to Loki/ELK once observability stack is wired.
  - The `/metrics` endpoint currently surfaces database pool utilisation only; extend via Prometheus once more signals are required.
- **Scaling**: increase `--workers` (or run additional processes) to clear job backlogs; bump concurrency one loop at a time and watch `scripts/embedding_metrics.sh` for throughput and error spikes. Postgres/Qdrant remain single-instance until HA work lands.
- **Queue hygiene**:
  - Ingests now enforce `CHESSMATE_MAX_PENDING_EMBEDDINGS` (default 250k). Set a higher limit or `0`/negative to bypass if you intentionally backfill.
  - Use `scripts/prune_pending_jobs.sh <batch>` to mark pending jobs with existing vectors as completed before re-ingesting.

#### OpenAI Retry Tuning
- Both the embedding worker and GPT-5 agent client retry transient OpenAI failures with exponential backoff (default: 5 attempts, 200 ms base delay, multiplier 2.0, jitter 20%).
- Override the defaults via environment:
  - `OPENAI_RETRY_MAX_ATTEMPTS` — positive integer (shared across worker/API).
  - `OPENAI_RETRY_BASE_DELAY_MS` — base backoff delay in milliseconds.
- Each retry emits a log line on stderr prefixed with `[openai-embedding]` or `[openai-agent]`, describing the attempt count, error, and next delay; scrape these in production to monitor rate limiting or outages.

### Embedding Queue Monitoring & Performance
- **Continuous telemetry:**
  ```sh
  DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
    scripts/embedding_metrics.sh --interval 120 --log logs/embedding-metrics.log
  ```
  Captures per-status counts, 5/15/60 minute throughput, and ETA. Store the log in source control ignored `logs/` for easy diffing.
- **Interpreting output:**
  - `pending` should trend down when workers keep pace; a plateau signals rate limits or stalled workers.
  - `throughput/min` columns help decide when to scale workers or revisit OpenAI quotas.
  - `pending ETA` is computed from the 15-minute rate—treat it as a sanity check, not an SLA.
  - Because vectors are not yet persisted to Qdrant, the worker marks jobs complete after reserving a `vector_id`. Expect Qdrant dashboards to stay quiet until the upload step ships.
- **Guard tuning:**
  - `CHESSMATE_MAX_PENDING_EMBEDDINGS=400000` is a good ceiling for local runs; production should tailor it to OpenAI/Qdrant quotas.
  - Export the variable per shell or bake it into systemd units for ingest jobs.
- **Scaling strategy:**
  - Increase `--workers` gradually; if the metrics script shows rising failures (e.g., repeated 429s) roll back concurrency or raise backoff.
  - When the queue dips below 10k pending, consider dropping back to a single worker to conserve tokens.

### Bulk Ingestion Runbook
1. **Prep** – export `DATABASE_URL`, set/confirm `CHESSMATE_MAX_PENDING_EMBEDDINGS`, and start the metrics loop (`--interval 120` works well for 5–10 worker threads).
2. **Dry-run diagnostics** – run `chessmate twic-precheck <pgn>` or spot-check the file for encoding with the troubleshooting commands below.
3. **Ingest** – execute `chessmate ingest <file.pgn>`; if the guard trips, either pause to let the queue drain or raise the threshold intentionally.
4. **Embed** – keep the worker running (`dune exec services/embedding_worker/embedding_worker.exe -- --workers N --poll-sleep 1.0`) and verify completions rise faster than pending. For one-off drains, add the new auto-shutdown flag—e.g. `dune exec services/embedding_worker/embedding_worker.exe -- --workers N --poll-sleep 1.0 --exit-after-empty 3` exits after three empty polls and prints the summary without needing Ctrl-C.
5. **Prune duplicates** – after re-ingest cycles, call `scripts/prune_pending_jobs.sh <batch>` until it reports `0` to clear leftover vectorized positions.
6. **Post-run checks** – capture the final metrics snapshot, confirm `pending` is near zero, and archive logs for observability.

### Agent Operations
- API and CLI calls automatically include agent insights when `AGENT_API_KEY` is present.
- Monitor agent warnings returned by the API (e.g., "Agent evaluation failed..." or token usage summaries).
- Tune `AGENT_REASONING_EFFORT` + `AGENT_VERBOSITY` jointly (high/high for deep audits, medium/medium for balanced responses).
- Enable caching by pointing `AGENT_CACHE_REDIS_URL` at the shared Redis instance (optionally tune `AGENT_CACHE_REDIS_NAMESPACE` / `AGENT_CACHE_TTL_SECONDS`). Without Redis, set `AGENT_CACHE_CAPACITY=<n>` (e.g. 1000) for the per-process fallback and clear or lower the value if memory pressure appears.
- Inspect cache contents via the container (host machines may not have `redis-cli`):
  ```sh
  docker compose exec redis redis-cli --scan --pattern 'chessmate:agent:*'
  ```
  If no keys appear, generate agent traffic (e.g. run a `chessmate query ...` with `AGENT_API_KEY` set) and retry.
  Spot-check PGN availability without re-ingesting:
  ```sh
  docker compose exec postgres psql "$DATABASE_URL" \
    -c "SELECT id, LENGTH(pgn) FROM games ORDER BY id LIMIT 5;"
  ```
  (Any SQL client hitting `DATABASE_URL` works—our services now use the Caqti connection pool, so `psql` is optional.) Non-zero lengths confirm PGNs are intact for agent retrieval.
- Force Redis snapshots when you expect `data/redis` to populate immediately (default policy `--save 60 1` waits for a write + 60 seconds):
  ```sh
  docker compose exec redis redis-cli SAVE    # synchronous
  docker compose exec redis redis-cli BGSAVE  # background
  docker compose exec redis ls -l /data       # inspect persisted files
  ```
- Flush stale agent entries after prompt/schema tweaks:
  - Single command (dev-sized datasets):
    ```sh
    redis-cli --scan --pattern 'chessmate:agent:*' | xargs -r redis-cli del
    ```
    Streams matching keys via `SCAN` and deletes them with `DEL`; adjust the pattern when you override `AGENT_CACHE_REDIS_NAMESPACE`.
  - Large keysets: avoid long `xargs` invocations by looping:
    ```sh
    redis-cli --scan --pattern 'chessmate:agent:*' \
      | while read -r key; do redis-cli del "$key" >/dev/null; done
    ```
  - Quick reset: temporarily change `AGENT_CACHE_REDIS_NAMESPACE` (e.g. append a timestamp), restart the API, and continue working with a fresh namespace.
  - Full wipe: `redis-cli FLUSHDB` removes the entire database—only use it when no other services share the Redis instance.
- Telemetry: each agent call logs a `[agent-telemetry]` JSON line with candidate counts, latency, token usage, and optional cost estimates. Configure per-1K token costs via `AGENT_COST_INPUT_PER_1K`, `AGENT_COST_OUTPUT_PER_1K`, and `AGENT_COST_REASONING_PER_1K` to surface USD totals.
- If GPT-5 is unreachable, results fall back to heuristic scoring and a warning appears in the response; investigate network/API limits before re-enabling.

## Backups & Restore
- **Postgres**: schedule `pg_dump` + WAL archiving; store artifacts in secure object storage.
- **Qdrant**: use built-in snapshots (`qdrant snapshot create --path /qdrant/storage/snapshots/<ts>`); sync to external storage.
- **Restore workflow**: stop services → restore Postgres dump → restore Qdrant snapshot → rerun migrations (if needed) → restart worker/API → re-ingest if deltas are missing.

## Security & Access
- Terminate TLS at reverse proxy (nginx/Traefik) in front of API & Qdrant.
- Protect Qdrant with auth (token/mTLS); rotate credentials regularly.
- Restrict worker egress to OpenAI hosts via firewall rules.
- Separate Postgres roles (application vs. admin) and use least privilege.
- Rotate `OPENAI_API_KEY`, DB passwords, and tokens per incident response policy.

## Monitoring & Alerting
- Track: API latency/p95, query success rate, embedding throughput, job queue depth (via `scripts/embedding_metrics.sh` or SQL), Postgres replication lag, disk usage on `data/` volumes.
- Alerts: latency > 2s sustained, backlog > 500 jobs, embedding failure rate > 5%/h, disk utilization > 80%, Qdrant/DB down. Hook alerts into the guard limits to warn before ingest halts.
- Dashboard: combine Postgres exporter, Qdrant metrics, OCaml counters (future Prometheus integration), and log the metrics script output for lightweight visibility.

## Incident Response
1. Acknowledge alert/page.
2. Check dashboards/logs for correlated spikes.
3. If Qdrant down: return 503s quickly, pause worker.
4. If Postgres degraded: pause ingestion, run read-only mode.
5. Capture root cause + mitigation in `docs/INCIDENTS/<date>.md`; assign follow-up actions.

## Maintenance Procedures
- Schema changes: schedule during low traffic; return maintenance responses (503) for API.
- Re-embedding jobs: throttle worker to stay within OpenAI quota; monitor queue depth/durations and prune completed vectors from the pending queue before re-running (`scripts/prune_pending_jobs.sh`).
- Upgrades: bump Docker images, apply migrations, run smoke tests (`chessmate query "test"`), restart services.
- Stack reset: `docker compose down`; remove `data/postgres`, `data/qdrant`; bring services back up, re-run migrations, re-ingest.

## CI/CD Considerations
- GitHub Actions (`.github/workflows/ci.yml`) runs `dune build` + `dune test` on pushes/PRs.
- Use pull-request checks as gatekeepers before deploy.
- For release candidates: document validation commands (`dune build`, `dune runtest`, sample ingest/query run) in PR description.
- Future hardening: add integration suite hitting `/query` against live Postgres/Qdrant in CI/CD, automate container builds/pushes.
