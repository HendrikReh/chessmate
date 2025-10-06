# Operations Playbook

## Service Topology
- **postgres**: canonical PGN/metadata store, embedding job queue. Volume: `data/postgres`.
- **qdrant**: vector store for FEN embeddings, exposed on 6333/6334. Volume: `data/qdrant`.
- **chessmate-api**: Opium HTTP service (prototype) for `/query`.
- **embedding-worker**: OCaml worker polling `embedding_jobs`, calling OpenAI, updating Qdrant/Postgres.
- **(optional) redis/others**: future queue/cache components once required.

## Bootstrapping Environment
```sh
# set connection strings for local dev
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
export CHESSMATE_API_URL=http://localhost:8080

# start core services (first run pulls images)
docker compose up -d postgres qdrant

# apply migrations (idempotent)
./scripts/migrate.sh

# seed sample PGNs (optional)
chessmate ingest test/fixtures/extended_sample_game.pgn
```

### Service Startup
- Query API (prototype): `dune exec chessmate_api -- --port 8080`.
- Embedding worker: `OPENAI_API_KEY=... chessmate embedding-worker`.
- CLI queries: `chessmate query "find king's indian games"` (ensure API is running).

## Runtime Management
- **Health checks**:
  - API: `GET /health`.
  - Postgres: `docker compose exec postgres pg_isready -U chess`.
  - Qdrant: `curl http://localhost:6333/healthz`.
- **Logs**: `docker compose logs -f <service>`; ship to Loki/ELK once observability stack is wired.
- **Scaling**: replicate `embedding-worker` to clear job backlogs; Postgres/Qdrant remain single-instance until HA work lands.

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
- Track: API latency/p95, query success rate, embedding throughput, job queue depth, Postgres replication lag, disk usage on `data/` volumes.
- Alerts: latency > 2s sustained, backlog > 500 jobs, embedding failure rate > 5%/h, disk utilization > 80%, Qdrant/DB down.
- Dashboard: combine Postgres exporter, Qdrant metrics, and OCaml counters (future Prometheus integration).

## Incident Response
1. Acknowledge alert/page.
2. Check dashboards/logs for correlated spikes.
3. If Qdrant down: return 503s quickly, pause worker.
4. If Postgres degraded: pause ingestion, run read-only mode.
5. Capture root cause + mitigation in `docs/INCIDENTS/<date>.md`; assign follow-up actions.

## Maintenance Procedures
- Schema changes: schedule during low traffic; return maintenance responses (503) for API.
- Re-embedding jobs: throttle worker to stay within OpenAI quota; monitor queue depth/durations.
- Upgrades: bump Docker images, apply migrations, run smoke tests (`chessmate query "test"`), restart services.
- Stack reset: `docker compose down`; remove `data/postgres`, `data/qdrant`; bring services back up, re-run migrations, re-ingest.

## CI/CD Considerations
- GitHub Actions (`.github/workflows/ci.yml`) runs `dune build` + `dune test` on pushes/PRs.
- Use pull-request checks as gatekeepers before deploy.
- For release candidates: document validation commands (`dune build`, `dune runtest`, sample ingest/query run) in PR description.
- Future hardening: add integration suite hitting `/query` against live Postgres/Qdrant in CI/CD, automate container builds/pushes.
