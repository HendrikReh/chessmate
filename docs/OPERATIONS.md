# Operations Playbook

## Service Topology
- `postgres`: stores canonical PGNs, metadata, and job queues. Bound to `data/postgres` for persistence.
- `qdrant`: vector store for FEN embeddings, exposed on 6333/6334. Uses `data/qdrant` volume.
- `chessmate-api`: HTTP service handling NL queries, hybrid planning, and response rendering.
- `embedding-worker`: background OCaml worker ingesting FEN jobs, calling OpenAI, and syncing Qdrant + Postgres.
- `redis` (optional): queue backend if Postgres LISTEN/NOTIFY is insufficient.

## Deployment
1. Copy `.env.example` → `.env` and fill secrets (`DATABASE_URL`, `QDRANT_URL`, `OPENAI_API_KEY`).
2. `docker-compose pull` (or `build` for internal services) then `docker-compose up -d`.
3. Run database migrations: `docker-compose exec postgres psql -U chessmate -f scripts/migrate.sql` (or `dune exec scripts/migrate.exe` once implemented).
4. Warm caches by running `dune exec chessmate -- ingest fixtures/sample.pgn` against the live stack.

## Runtime Management
- Health checks: `/health` (API), `/metrics` (Prometheus once wired), Postgres `pg_isready`, Qdrant `/healthz`.
- Logs: use `docker-compose logs -f <service>` or ship to centralized collector (Loki/ELK) via sidecars.
- Scaling: replicate `embedding-worker` to handle spikes; keep `postgres` and `qdrant` single instances unless failover design added.

## Backups & Restore
- Postgres: nightly `pg_dump` stored in secure object storage + WAL archiving for PITR.
- Qdrant: schedule `qdrant snapshot create --path /qdrant/storage/snapshots/<timestamp>` via cron container.
- Restore procedure: stop services → restore Postgres dump → restore Qdrant snapshot → restart workers → re-run ingestion to reconcile deltas.

## Security & Access
- Place services behind a reverse proxy (Traefik/nginx) terminating TLS.
- Enable basic auth or mTLS for Qdrant HTTP API; rotate tokens quarterly.
- Restrict embedding worker egress to OpenAI endpoints via firewall rules.
- Use separate Postgres roles for application (`chessmate_app`) and admin tasks.

## Monitoring & Alerting
- Metrics to track: request latency, query success rate, embedding throughput, queue depth, Postgres replication lag.
- Alerts: API latency > 2s sustained, worker queue backlog > 500 items, embedding failures > 5% per hour, disk usage > 80% on `data/` volumes.
- Dashboard: combine Postgres exporter, Qdrant Prometheus metrics, and custom OCaml counters.

## Incident Response Checklist
1. Acknowledge alert in paging tool.
2. Inspect logs + metrics for correlated spikes.
3. If Qdrant unavailable, fail queries fast (API returns 503) and disable workers.
4. If Postgres degraded, pause ingestion and run read-only mode until recovery.
5. Document root cause, mitigation, and follow-up tasks in `docs/INCIDENTS/<date>.md`.

## Maintenance Windows
- Schedule schema changes during off-peak hours; place API in maintenance mode (return 503 with message).
- Re-embed runs: throttle to protect OpenAI quota; monitor queue depth.
- Upgrade process: update `docker-compose.yml` image tags, apply migrations, run smoke tests (`dune exec chessmate -- query "test run"`).

## CI/CD Operations
- Workflow file: `.github/workflows/ci.yml` executes on pushes to `main`, feature branches, and all PRs.
- Runner: `ubuntu-latest` with OCaml 5.1.0 via `ocaml/setup-ocaml@v2` (caching disabled for portability).
- Job sequence: dependency install → `dune build` → `dune test`.
- Alerting: configure GitHub notification settings so failures page the on-call engineer; optionally mirror to ChatOps via GitHub webhooks.
- Maintenance: update the workflow when OCaml/dune versions change; verify new versions by running the action on a feature branch before merging.
