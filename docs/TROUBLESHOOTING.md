# Troubleshooting Playbook (2025-10-xx)

Quick diagnostics and fixes for common Chessmate issues. Use alongside [OPERATIONS.md](OPERATIONS.md), [DEVELOPER.md](DEVELOPER.md), and [TESTING.md](TESTING.md).

---

## 1. First-Line Sanity

Run this loop whenever you reset dependencies or suspect ingest/embedding is wedged:

0. **Config sanity**
   ```sh
   dune exec -- chessmate -- config
   ```
   Exit code `0` means required services/env vars are ready. A `2` indicates optional components (e.g. Redis) are skipped, and `1` surfaces fatal issues alongside remediation hints.

1. **Postgres connectivity**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate      psql "$DATABASE_URL" -c "SELECT 1"
   ```
   Startup logs (API/worker) print `[config]` lines; fix any `missing` variables before proceeding.

2. **Ingest a known-good PGN**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate      dune exec chessmate -- ingest data/games/twic1611.pgn
   ```

3. **Check vector IDs**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate      psql "$DATABASE_URL" -c "SELECT COUNT(*) FROM positions WHERE vector_id IS NOT NULL"
   ```

4. **Run the worker with auto-shutdown**
   ```sh
   set -a; source .env
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate    QDRANT_URL=http://localhost:6333      dune exec -- embedding_worker -- --workers 3 --poll-sleep 1.0 --exit-after-empty 3
   ```

5. **Watch queue status**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate      psql "$DATABASE_URL" -c "SELECT status, COUNT(*) FROM embedding_jobs GROUP BY status"
   ```
   `pending` should drop while `completed` rises. Use `scripts/embedding_metrics.sh --interval 120` for a live view.

---

## 2. PGN Ingestion Issues

| Symptom | Diagnosis | Fix |
| --- | --- | --- |
| `invalid byte sequence for encoding "UTF8"` | PGNs ship in Windows-1252 | `iconv -f WINDOWS-1252 -t UTF-8//TRANSLIT ...` before ingest |
| `PGN contained no moves` | Editorial fragments/missing `[Result]` | `dune exec chessmate -- twic-precheck file.pgn`; clean flagged entries |
| Only first game stored | Legacy single-game build | Update binary; current ingest handles multi-game PGNs |

---

## 3. Environment Setup Problems

| Symptom | Root Cause | Solution |
| --- | --- | --- |
| `opam: "open" failed on ... config.lock` | Shell sandboxing writes | Run `eval "$(opam env --set-switch)"` instead of `opam switch set .` |
| `Program 'chessmate_api' not found` | Using public name | `dune exec -- chessmate-api --port 8080` or `dune exec -- services/api/chessmate_api.exe -- --port 8080` |

---

## 4. Database & Vector Store

| Symptom | What it Means | What to Do |
| --- | --- | --- |
| `/query` warns `Vector search unavailable` | Qdrant unreachable | Verify `QDRANT_URL`, service up (`curl .../healthz`), restart API/worker |
| Embedding jobs stuck `pending` | Worker not running or auth issue | Check worker logs, ensure `OPENAI_API_KEY`, `QDRANT_URL`. Monitor with `scripts/embedding_metrics.sh` |
| Worker runs but vectors missing | Final write failing | Check queue stats, confirm Postgres `vector_id` counts, inspect Qdrant (`curl $QDRANT_URL/collections/positions/points/count`) |
| Agent warnings / missing `agent_score` | GPT‑5 failure or cache stale | Verify `AGENT_API_KEY`, model access, network; review `[agent-telemetry]` logs; flush Redis namespace if prompts changed |

Redis tips:
```sh
# inside container
docker compose exec redis redis-cli --scan --pattern 'chessmate:agent:*'

# force persistence
docker compose exec redis redis-cli SAVE
```

---

## 5. Rate Limiter, Health, & Metrics

| Symptom | Explanation | Action |
| --- | --- | --- |
| Frequent 429s | Quota too low or test load too high | Increase `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` temporarily or reduce concurrency |
| `/metrics` missing rate limit counters | API not exposing metrics | Ensure API is up; check logs for `[config]` lines |
| CLI health shows `qdrant error` | Dependency down | Inspect service logs; restart Qdrant/API |

Use `curl http://localhost:8080/metrics` to inspect Caqti pool and rate limiter gauges. Upcoming `/health` JSON will provide structured status per dependency.

---

## 6. Queue Management Hints
- Monitor regularly: `scripts/embedding_metrics.sh --interval 120 --log logs/embedding-metrics.log`
- Scale safely: a single process with `--workers N` loops is preferred. Increase `N` gradually.
- Prune stale jobs (e.g., when re-ingesting PGNs): `scripts/prune_pending_jobs.sh 2000`
- Throttle ingest automatically with `CHESSMATE_MAX_PENDING_EMBEDDINGS`; set to `0`/negative to disable.

---

## 7. CLI Command Reminders
- Export `DATABASE_URL` before ingesting/querying.
- `dune exec chessmate -- help` lists subcommands.

---

## 8. Smoke Test Checklist (One-Liners)
```sh
./scripts/migrate.sh
scripts/embedding_metrics.sh --interval 120
TOOL=oha DURATION=60s CONCURRENCY=50 ./scripts/load_test.sh
```

Document root causes and fixes in `docs/INCIDENTS/<date>.md` after major incidents. The quicker we capture proven remedies, the faster we recover next time.
