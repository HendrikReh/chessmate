# Operations Playbook (2025-10-xx)

Pair this runbook with the [Developer Handbook](DEVELOPER.md) for environment setup, the [Testing Plan](TESTING.md) for manual/automated checks, and [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for deep dives.

---

## 1. Service Topology
| Component | Role |
| --- | --- |
| **postgres** | Canonical store for PGNs, players/games/positions, embedding jobs (`data/postgres`). |
| **qdrant** | Vector database for FEN embeddings (`data/qdrant`). API/worker ensure collection on startup. |
| **redis** | Optional GPT‑5 evaluation cache (`data/redis`). |
| **chessmate-api** | Opium HTTP service exposing `/query`, `/metrics`, `/openapi.yaml`, `/health`. Includes per-IP rate limiting and structured dependency probes. |
| **embedding-worker** | Batches embedding jobs, calls OpenAI Embeddings, writes vectors to Qdrant, marks jobs complete. |

---

## 2. Bootstrapping
```sh
cp .env.sample .env
source .env  # or export variables manually

docker compose up -d postgres qdrant redis
./scripts/migrate.sh
```
Optional: seed PGNs via `dune exec chessmate -- ingest ...`.

Ensure the Postgres user has `CREATEDB` (required for integration tests):
```sh
docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"
```

---

## 3. Service Startup
| Command | Purpose |
| --- | --- |
| `dune exec -- services/api/chessmate_api.exe --port 8080` | Start the query API. Logs include rate-limiter quota and Qdrant bootstrap status. |
| `OPENAI_API_KEY=... dune exec -- embedding_worker -- --workers N --poll-sleep 1.0 --exit-after-empty 3` | Run embedding worker loops. Adjust `N` gradually; monitor queue via `scripts/embedding_metrics.sh --interval 120`. |
| `dune exec chessmate -- query [--limit N] [--offset N] [--json] "..."` | CLI queries; paginate with `--limit/--offset` and use `--json` for raw payloads. Prints `[health] ...` lines before execution. |
| `curl http://localhost:8080/metrics` | Inspect Prometheus gauges/counters (DB pool usage, per-route latency histograms, agent cache stats, rate limiter). |
| `curl http://localhost:8080/openapi.yaml` | Retrieve the OpenAPI spec (override path with `CHESSMATE_OPENAPI_SPEC`). |
| `curl http://localhost:8080/health` | Structured JSON health report (HTTP 200 on `status=ok`, 503 otherwise). Worker exposes `http://localhost:${CHESSMATE_WORKER_HEALTH_PORT:-8081}/health`. |

### Health Endpoints

`/health` returns sanitized dependency probes with per-check latency:

```sh
curl -s http://localhost:8080/health | jq
```

```json
{
  "status": "ok",
  "checks": [
    { "name": "postgres", "status": "ok", "required": true, "latency_ms": 2.1, "detail": "pending_jobs=0 in_use=0 waiting=0 capacity=10" },
    { "name": "qdrant", "status": "ok", "required": true, "latency_ms": 15.4, "detail": "200 /healthz" },
    { "name": "redis", "status": "skipped", "required": false, "detail": "agent disabled" },
    { "name": "openai", "status": "ok", "required": false, "detail": "model=gpt-5" }
  ]
}
```

Required dependency failures drive `status="error"` (HTTP 503). Optional failures flip the status to `degraded` (also 503) so dashboards can alert without dropping traffic entirely. The embedding worker exposes the same schema:

```sh
PORT=${CHESSMATE_WORKER_HEALTH_PORT:-8081}
curl -s "http://localhost:${PORT}/health" | jq
```

Override the listener via `CHESSMATE_WORKER_HEALTH_PORT` when co-locating multiple workers.

---

## 4. Integration Smoke Test
```sh
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
eval "$(opam env --set-switch)"
dune exec test/test_main.exe -- test integration
```
Exercises ingest → embedding pipeline → hybrid query. Vector hits are stubbed, so Qdrant/OpenAI aren’t required.

---

## 5. Runtime Operations
- **Health checks**: `curl http://localhost:8080/health`, `curl http://localhost:${CHESSMATE_WORKER_HEALTH_PORT:-8081}/health`, `pg_isready`, `curl http://qdrant:6333/healthz`, `redis-cli PING`.
- **Worker metrics**: `curl http://localhost:${CHESSMATE_WORKER_HEALTH_PORT:-8081}/metrics` returns processed/failed job totals, throughput gauges, and current queue depth.
- **Metrics**: `/metrics` exposes DB pool usage, per-route latency/error histograms (`api_request_latency_ms_pXX{route="..."}`), agent cache hit/miss totals, circuit breaker state, and rate limiter counters.
- **Agent candidate tuning**: adjust `AGENT_CANDIDATE_MULTIPLIER` (default 5) and `AGENT_CANDIDATE_MAX` (default 25) to control how many games the GPT-5 evaluator inspects per query.
- **Rate limiter**: 429 responses include `Retry-After`. Tune `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` (and optional `..._BUCKET_SIZE`) as needed. Enable per-IP body budgets via `CHESSMATE_RATE_LIMIT_BODY_BYTES_PER_MINUTE`; monitor `api_rate_limited_body_total`. `CHESSMATE_MAX_REQUEST_BODY_BYTES` caps individual request size (set `0` to disable). See [Rate Limiter HTTP test](../test/test_rate_limiter_http.ml) for coverage.
- **Embedding queue monitoring**: `scripts/embedding_metrics.sh --interval 120` (processed, pending, ETA). Worker quits automatically if `--exit-after-empty` is set. Jobs/minute and characters/sec are also written to the optional `CHESSMATE_WORKER_METRICS_PATH` textfile for Prometheus textfile scraping.
- **Graceful shutdown**: API/worker handle SIGINT/SIGTERM; look for `[shutdown]` logs confirming clean exit.

---

## 6. Runbooks

| Scenario | Runbook |
| --- | --- |
| Circuit breaker opened, agent disabled | [docs/runbooks/circuit-breaker.md](runbooks/circuit-breaker.md) |
| GPT‑5 agent timeouts | [docs/runbooks/agent-timeouts.md](runbooks/agent-timeouts.md) |
| Capacity planning & scaling | [docs/runbooks/capacity-planning.md](runbooks/capacity-planning.md) |
| Incident retrospectives | [docs/INCIDENTS/incident-template.md](INCIDENTS/incident-template.md) |

## 7. Degraded Modes & Incident Hints
| Symptom | Behaviour | Remedy |
| --- | --- | --- |
| Qdrant unreachable | API logs `Vector search unavailable`, falls back to metadata-only results. CLI health shows `qdrant error`. | Check Qdrant service (`docker compose ps qdrant`, `/healthz`), restart; ensure config (`QDRANT_URL`). |
| Rate limiter triggered heavily | `429` responses + `api_rate_limited_total` increases. | Raise per-IP quota for the test window or reduce concurrency; verify legitimate traffic isn’t starved. |
| GPT‑5 latency/timeouts (future) | Planned: warnings in response (`agent timeout`) + circuit-breaker logs. | Investigate OpenAI limits, fall back to heuristic mode, adjust timeout env (`AGENT_REQUEST_TIMEOUT_SECONDS`). |
| Postgres saturation | High `db_pool_waiting`, CPU spikes. | Increase `CHESSMATE_DB_POOL_SIZE`, scale Postgres vertically/horizontally, audit slow queries. |

Log details and mitigation in `docs/INCIDENTS/<date>.md` after an incident.

---

## 7. Backups & Restore
| Component | Strategy |
| --- | --- |
| Postgres | Regular `pg_dump` + WAL archiving; store in secure object storage. |
| Qdrant | Use built-in snapshots (`qdrant snapshot create --path ...`). |
| Redis | RDB snapshots (`redis-cli SAVE` / `BGSAVE`); consider separate instances per environment. |

**Restore order**: stop services → restore Postgres → restore Qdrant snapshot → rerun migrations (if needed) → restart worker/API → re-ingest missing deltas.

---

## 9. Maintenance Jobs
- Schema changes: schedule during low traffic; respond with 503s if maintenance window is required.
- Mass re-embedding: throttle worker (`--workers` and `--poll-sleep`), watch OpenAI quotas and queue depth.
- Redis cache maintenance: flush namespace (`redis-cli --scan --pattern 'chessmate:agent:*' | xargs -r redis-cli del`) or bump `AGENT_CACHE_REDIS_NAMESPACE` when prompts change.

---

## 10. Security & Access
- Terminate TLS at a reverse proxy (nginx/Traefik) in front of API & Qdrant.
- Protect Qdrant with authentication (token/mTLS); rotate secrets regularly.
- Restrict worker/API egress to OpenAI endpoints via firewall rules.
- Use least-privilege Postgres roles; store credentials in a secret manager.
- Rotate `OPENAI_API_KEY`, DB passwords, Redis credentials per incident response policy.

---

## 11. Monitoring & Alerting (Targets)
- **Metrics to watch**: `/metrics` latency histograms, DB pool usage, rate limiter counters, embedding throughput, queue depth, GPT‑5 timeout counts.
- **Alerts**:
  - API p95 > 2s sustained.
  - Embedding backlog > 500 jobs for >10 min.
  - Embedding failure rate > 5%/h.
  - Disk usage on `data/` volumes > 80%.
  - Postgres/Qdrant health probe failures.
- Dashboards: combine Postgres exporter, Qdrant metrics, OCaml counters, and logs from `scripts/embedding_metrics.sh`.

---

## 12. CI/CD Notes
- GitHub Actions runs `dune build` + `dune runtest`; required checks gate merges.
- `dune build @fmt` enforces ocamlformat.
- For releases: document validation commands in the PR (build/test/smoke), ensure the embedding worker/API restart cleanly, publish containers, and announce rollout steps.
- Future goal: automated integration tests hitting `/query` against live Postgres/Qdrant in CI/CD.

---

Keep this playbook updated alongside system changes. Combine it with the architecture roadmap ([REVIEW_v4.md](REVIEW_v4.md)) to understand what’s changing and why. Incident retrospectives live in `docs/INCIDENTS/`; use the template in `docs/INCIDENTS/incident-template.md` after each SEV event.
