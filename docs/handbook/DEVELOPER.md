# Developer Handbook

This handbook gets you from zero to productive with Chessmate: installing dependencies, understanding
configuration, and running the core services. For architecture diagrams and reliability plans see
[ARCHITECTURE.md](ARCHITECTURE.md) and [REVIEW_v5.md](REVIEW_v5.md).

---

## 1. Quick Start

```sh
./bootstrap.sh
```

The bootstrap script is idempotent. It:
- Creates/loads the repo-specific opam switch and installs dependencies.
- Copies `.env.sample` → `.env` (if missing).
- Starts Docker services (Postgres, Qdrant, Redis) and runs migrations.
- Executes `dune build` + `dune runtest`.

After any manual changes to environment variables or service credentials, run:
```sh
dune exec -- chessmate -- config
```
Exit codes: `0` (everything ready), `2` (warnings for optional dependencies such as Redis), `1` (fatal configuration error; the command prints remediation hints).

If you prefer manual setup, follow the prerequisites below then run the same commands yourself.

---

## 2. Prerequisites

| Requirement | Notes |
| --- | --- |
| OCaml 5.1.x + opam | `opam switch create . 5.1.0` (bootstrap does this). |
| ocamlformat 0.27.0 | `opam install ocamlformat.0.27.0` (matching `.ocamlformat`). |
| Docker & Docker Compose | Used for Postgres, Qdrant, Redis. |
| `psql`, `curl`, `redis-cli` | Helpful for troubleshooting. |
| OpenAI API key (optional) | Required only if you exercise GPT‑5 agent scoring. |

Load the opam environment in each shell:
```sh
eval "$(opam env --set-switch)"
```

---

## 3. Configuration Reference

The executables validate configuration on startup; missing or malformed values result in descriptive errors.

| Variable | Required | Default | Used by | Notes |
| --- | --- | --- | --- | --- |
| `DATABASE_URL` | ✅ | — | API, worker, CLI | Postgres connection string. |
| `QDRANT_URL` | ✅ | — | API, worker | Base URL for Qdrant. |
| `CHESSMATE_API_PORT` | ⛏️ | `8080` | API | HTTP port. |
| `CHESSMATE_API_URL` | ⛏️ | `http://localhost:8080` | CLI | Location of the query API. |
| `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` | ⛏️ | `60` | API | Per-IP quota for the rate limiter. |
| `CHESSMATE_RATE_LIMIT_BUCKET_SIZE` | ⛏️ | same as requests/min | API | Optional burst capacity. |
| `CHESSMATE_RATE_LIMIT_BODY_BYTES_PER_MINUTE` | ⛏️ | — (disabled) | API | Optional per-IP body-size quota in bytes per minute. |
| `CHESSMATE_RATE_LIMIT_BODY_BUCKET_SIZE` | ⛏️ | same as bytes/min | API | Optional burst capacity for body quota. |
| `CHESSMATE_MAX_REQUEST_BODY_BYTES` | ⛏️ | `1048576` | API | Request body limit; `0` disables the middleware. |
| `QDRANT_COLLECTION_NAME` | ⛏️ | `positions` | API, worker | Collection ensured at startup. |
| `QDRANT_VECTOR_SIZE` | ⛏️ | `1536` | API, worker | Embedding dimension. |
| `QDRANT_DISTANCE` | ⛏️ | `Cosine` | API, worker | Distance metric. |
| `CHESSMATE_MAX_PENDING_EMBEDDINGS` | ⛏️ | `250000` | CLI ingest | Queue guard for ingestion; `<=0` disables. |
| `CHESSMATE_INGEST_CONCURRENCY` | ⛏️ | `4` | CLI ingest | Parallel PGN parsing. |
| `OPENAI_API_KEY` | ✅ (worker) | — | Embedding worker | Required for embeddings. |
| `AGENT_API_KEY` | ⛏️ | — | API | Enables GPT‑5 re-ranking. |
| `AGENT_REASONING_EFFORT`, `AGENT_VERBOSITY` | ⛏️ | `medium` | API | Tune GPT‑5 calls. |
| `AGENT_CACHE_REDIS_URL` | ⛏️ | — | API | Redis-backed agent cache. |
| `OPENAI_RETRY_MAX_ATTEMPTS` | ⛏️ | `5` | CLI/API/worker | Positive integer; overrides retry attempts for OpenAI calls. |
| `OPENAI_RETRY_BASE_DELAY_MS` | ⛏️ | `200` | CLI/API/worker | Positive float (milliseconds) controlling initial retry backoff. |
| `OPENAI_EMBEDDING_CHUNK_SIZE` | ⛏️ | `2048` | Worker | Positive integer; maximum FEN batch size per embedding request. |
| `OPENAI_EMBEDDING_MAX_CHARS` | ⛏️ | `120000` | Worker | Positive integer; character limit per batch (requests split recursively when exceeded). |

✅ = required · ⛏️ = optional.

---

## 4. Everyday Workflow

1. **Verify GPL headers**
   ```sh
   scripts/check_gpl_headers.sh
   ```
   The bootstrap script configures a pre-commit hook to run this check locally; CI blocks merges if a source file is missing the standard header.

2. **Format & test before commit**
   ```sh
   dune fmt
   dune build
   dune runtest
   ```
   CI runs `dune build @fmt` to enforce formatting (profile `conventional`, version `0.27.0`).

3. **Run the embedding worker**
   ```sh
   OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate      dune exec -- embedding_worker -- --workers 2 --poll-sleep 1.0 --exit-after-empty 3
   ```
   Monitors: `scripts/embedding_metrics.sh --interval 120`.

4. **Run the query API**
   ```sh
   dune exec -- services/api/chessmate_api.exe --port 8080
   ```
   Logs include rate-limiter configuration and Qdrant bootstrap status.

5. **Query from the CLI**
   ```sh
   CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query --json "Show 5 random games"
   ```
   Output includes dependency health, rate-limit responses, and JSON payloads when `--json` is used.

6. **Integration smoke test**
   ```sh
   export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
   dune exec test/test_main.exe -- test integration
   ```
   Stubs Qdrant/OpenAI but exercises ingest → query flows.

More recipes live in [COOKBOOK.md](COOKBOOK.md).

### Snapshot Workflow (Qdrant)
- Take snapshots before major reindex/migrations:
  ```sh
  dune exec -- chessmate -- collection snapshot --name nightly-backup --note "pre-reindex"
  ```
  Metadata is appended to `snapshots/qdrant_snapshots.jsonl`; override the log path with `CHESSMATE_SNAPSHOT_LOG` when archiving off-box.
- Restore by name (or explicit `--location`) after quiescing API/worker processes:
  ```sh
  dune exec -- chessmate -- collection restore --snapshot nightly-backup
  ```
- Inspect available snapshots plus local log entries:
  ```sh
  dune exec -- chessmate -- collection list
  ```

### Load Testing Harness
- Ensure a representative corpus is ingested and the API is running locally.
- Run the script with defaults (`60s`, 50 concurrent connections):
  ```sh
  TOOL=oha DURATION=60s CONCURRENCY=50 TARGET_URL=http://localhost:8080/query scripts/load_test.sh
  ```
- The script detects legacy `oha` flags, minifies the JSON payload once (avoiding `@payload` 400s), and resolves Docker Compose container IDs before grabbing a stats snapshot. It also prints `/metrics` immediately after the run—capture the output for PR validation.
- Monitor `api_request_latency_ms_p95`, `db_pool_wait_ratio`, `agent_cache_hits_total`, and Qdrant container CPU usage. Use `LOAD_TESTING.md` for deeper analysis checklists.

---

## 5. Observability & Health

- `/metrics` exposes Caqti pool gauges, rate-limiter counters, and (soon) per-dependency health/timeouts.
- CLI prints `[health] postgres/qdrant/redis/api` lines before executing queries. Run `dune exec -- chessmate -- config` to see the full dependency report at any time.
- API and worker expose `/health` (JSON) and `/metrics` on their respective ports (worker defaults to `CHESSMATE_WORKER_HEALTH_PORT`, 8081). Worker metrics include processed/failed totals and current queue depth.
- Use `scripts/embedding_metrics.sh` to monitor queue depth; rate limiter increments appear under `api_rate_limited_total`.

---

## 6. Troubleshooting Tips

| Symptom | Likely Cause | Next Steps |
| --- | --- | --- |
| `Rate limit exceeded` (429) | Per-IP quota hit | Check `CHESSMATE_RATE_LIMIT_*` env vars; inspect `/metrics`. |
| Qdrant errors on ingest | Collection missing | Confirm bootstrap logs (`qdrant collection ensured`); check `QDRANT_URL`. |
| Slow/blocked queries | GPT‑5 latency | Watch logs for `[agent-timeout]`; upcoming circuit breaker will auto-fallback. |
| Integration test fails immediately | DB permissions | Ensure `CHESSMATE_TEST_DATABASE_URL` user has `CREATEDB`. |
| Agent cache misses unexpectedly | Redis not configured | Set `AGENT_CACHE_REDIS_URL` or fall back to in-memory cache. |

For fuller debugging guidance see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) and [Operations Playbook](OPERATIONS.md).

Happy hacking! Chessmate keeps ingestion, vector search, and LLM scoring under your control—run the smoke test often and keep the guardrails tight.
