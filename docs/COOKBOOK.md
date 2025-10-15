# Chessmate Cookbook – Quick Recipes

Task-focused snippets you can copy/paste. Each recipe points to the primary docs for context.

> Need background? Start with the [Developer Handbook](DEVELOPER.md), [Operations Playbook](OPERATIONS.md), or [Testing Plan](TESTING.md).

---

## 1. Bootstrap Your Dev Environment
```
./bootstrap.sh
```
Installs deps, copies `.env` if missing, starts Docker services, runs migrations, and executes `dune build && dune runtest`. Idempotent—rerun whenever your environment drifts.

---

## 2. Ingest a PGN & Query the API
```
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
export CHESSMATE_API_URL=http://localhost:8080
docker compose up -d postgres qdrant redis
./scripts/migrate.sh

dune exec chessmate -- ingest test/fixtures/extended_sample_game.pgn
dune exec -- services/api/chessmate_api.exe --port 8080 &
CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Show King's Indian games"
```
Add `--json` for machine-readable output. Rate limiter responses (429 + `Retry-After`) confirm guardrails are active.

---

## 3. Integration Smoke Test (End-to-End)
```
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"  # once
eval "$(opam env --set-switch)"
dune exec test/test_main.exe -- test integration
```
Validates ingest → embedding queue → query using disposable DBs. Vector hits are stubbed; no Qdrant/OpenAI required.

---

## 4. Drain the Embedding Queue After Bulk Import
```
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
export CHESSMATE_MAX_PENDING_EMBEDDINGS=400000
dune exec chessmate -- ingest data/games/twic1611.pgn

OPENAI_API_KEY=real-key   dune exec -- embedding_worker -- --workers 6 --poll-sleep 1.0 --exit-after-empty 3

scripts/embedding_metrics.sh --interval 120
```
`--exit-after-empty 3` stops workers automatically after three empty polls; metrics script shows throughput/backlog.

---

## 5. Format & Test Before Commit
```
dune fmt          # ocamlformat profile conventional/0.27.0
dune build
dune runtest
```
CI runs `dune build @fmt`; mismatches fail the pipeline.

---

## 6. Serve the OpenAPI Spec
```
dune exec -- services/api/chessmate_api.exe --port 8080 &
curl http://localhost:8080/openapi.yaml

# Use a custom spec
CHESSMATE_OPENAPI_SPEC=/tmp/openapi.yaml   dune exec -- services/api/chessmate_api.exe --port 8080
```
Pair with Redoc or swagger-ui for docs/previews.

---

## 7. Check Health & Metrics
```
curl http://localhost:8080/metrics
CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Show 5 random games"
```
Metrics include DB pool gauges and rate limiter counters. Planned `/health` JSON will provide per-dependency status (see [REVIEW_v4.md](REVIEW_v4.md)).

---

## 8. Reset the Stack
```
docker compose down
rm -rf data/postgres data/qdrant data/redis
docker compose up -d postgres qdrant redis
./scripts/migrate.sh
```
Follow with the integration smoke test to confirm the rebuild succeeded.

---

## 9. Snapshot Qdrant Before Reindexing
```
# Create a labelled snapshot and capture metadata (default log: snapshots/qdrant_snapshots.jsonl)
dune exec -- chessmate -- collection snapshot --name nightly-backup --note "before bulk reindex"

# List remote + locally recorded snapshots
dune exec -- chessmate -- collection list

# Restore from the latest recorded snapshot by name
sudo systemctl stop chessmate-api  # or stop docker compose services
CHESSMATE_SNAPSHOT_LOG=/backups/qdrant/log.jsonl \
  dune exec -- chessmate -- collection restore --snapshot nightly-backup
```
The CLI resolves snapshot locations either from the metadata log or live Qdrant list; provide `--location` when restoring from an off-box path.

---

## 10. Observe Rate Limiting (Optional)
```
CHESSMATE_API_URL=http://localhost:8080   for i in {1..70}; do dune exec -- chessmate -- query "Show 5 random games"; done
```
After the configured quota, requests return 429 with `Retry-After`. `/metrics` reports `api_rate_limited_total{ip}` increments.

---

## 11. Confirm Qdrant Bootstrap
```
dune exec -- services/api/chessmate_api.exe --port 8080
# Look for [chessmate-api][config] qdrant collection ensured (name=positions)

OPENAI_API_KEY=dummy   dune exec -- embedding_worker -- --workers 1
# Logs: [worker][config] qdrant collection ensured (name=positions)
```
Verifies the auto-creation flow so manual curl calls are unnecessary.

---

Grab these recipes as needed; dive into the linked docs for deeper explanations and troubleshooting.
