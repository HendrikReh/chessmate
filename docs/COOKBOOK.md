# Chessmate Cookbook

Short, task-focused recipes for everyday workflows. Each section links back to
the primary documentation for deeper context.

> Need full background instead? Start with the [Developer Handbook](DEVELOPER.md),
> [Operations Playbook](OPERATIONS.md), or [Testing Plan](TESTING.md).

---

## Bootstrap a Fresh Development Environment
```sh
./bootstrap.sh
```
What it does:
- Copies `.env.sample` to `.env` (if missing)
- Creates/loads the opam switch and installs dependencies
- Starts Docker services (Postgres, Qdrant, Redis) and runs migrations
- Runs `dune build` and `dune runtest`

You can re-run the script anytime you need to resynchronise dependencies; it skips steps that are already satisfied.

---

## Ingest a PGN and Issue a Query
```sh
# 1. Ensure services and env vars are ready
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
export CHESSMATE_API_URL=http://localhost:8080
docker compose up -d postgres qdrant redis
./scripts/migrate.sh

# 2. Ingest a sample game (respects CHESSMATE_MAX_PENDING_EMBEDDINGS)
dune exec chessmate -- ingest test/fixtures/extended_sample_game.pgn

# 3. Run the prototype API + query it from another shell
dune exec services/api/chessmate_api.exe -- --port 8080 &
dune exec chessmate -- query "Show King's Indian games with queenside pressure"
```
See also: [Operations – Service Startup](OPERATIONS.md#service-startup).

---

## Run the Integration Smoke Test
```sh
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
# grant CREATEDB once during setup
docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"
eval "$(opam env --set-switch)"
psql "$CHESSMATE_TEST_DATABASE_URL" -c '\conninfo'
dune exec test/test_main.exe -- test integration
```
Use this before releases or after schema changes to confirm ingest → query flows.
More detail: [Operations – Integration Smoke Test](OPERATIONS.md#integration-smoke-test).

---

## Drain the Embedding Queue for a Bulk Import
```sh
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
export CHESSMATE_MAX_PENDING_EMBEDDINGS=400000
docker compose up -d postgres qdrant redis

# Ingest a large PGN corpus
dune exec chessmate -- ingest data/games/twic1611.pgn

# Run N worker loops with an auto-shutdown when the queue empties
OPENAI_API_KEY=real-key \
  dune exec services/embedding_worker/embedding_worker.exe -- \
    --workers 6 --poll-sleep 1.0 --exit-after-empty 3

# Monitor progress every two minutes
scripts/embedding_metrics.sh --interval 120
```
Reference: [Operations – Embedding Queue Monitoring & Performance](OPERATIONS.md#embedding-queue-monitoring--performance).

---

## Inspect the OpenAPI Specification
```sh
# Serve the default spec from docs/openapi.yaml
dune exec services/api/chessmate_api.exe -- --port 8080 &
curl http://localhost:8080/openapi.yaml

# Optionally point to a custom spec file
CHESSMATE_OPENAPI_SPEC=/tmp/openapi.yaml \
  dune exec services/api/chessmate_api.exe -- --port 8080
```
Pairs well with tooling such as Redoc, swagger-ui, or code generators.
See: [docs/openapi.yaml](openapi.yaml) for the canonical definition.

---

## Reset the Local Stack
```sh
docker compose down
rm -rf data/postgres data/qdrant data/redis
docker compose up -d postgres qdrant redis
eval "$(opam env --set-switch)"
./scripts/migrate.sh
```
Handy when migrations or local data drift — follow up with the integration
recipe above to sanity check the rebuilt environment.
