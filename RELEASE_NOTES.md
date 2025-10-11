
# Release Notes

## 0.6.1 – Health Checks & Query JSON Mode

### Added
- Added dependency health checks (Postgres, Qdrant, Redis, API) before `chessmate query` executes.
- Introduced `--json` flag to `chessmate query` for raw API responses.

### Fix
- Fixed SQL whitespace bug affecting query pagination defaults.

### Notes
- Rebuilt review roadmap (docs/REVIEW_v4.md) and consolidated CLI docs.


## 0.6.0 – Caqti Repository Migration

### Changed
 **Caqti Migration Complete**
   - Replaced libpq shell wrapper with typed Caqti pool
   - Parameterized queries throughout (SQL injection risk eliminated)
   - Pool instrumentation via `/metrics` endpoint
   - Evidence: lib/storage/repo_postgres_caqti.ml:1-300, services/api/chessmate_api.ml:278-301

2. **Vector Upload Implemented**
   - Worker now uploads embeddings to Qdrant with retry logic
   - Payload enrichment from Postgres metadata
   - 3-attempt exponential backoff for transient failures
   - Evidence: services/embedding_worker/embedding_worker.ml:142-192

3. **Secret Sanitization**
   - Regex-based redaction of API keys, database URLs, Redis URIs
   - Applied to all error messages and logs
   - Test coverage in place
   - Evidence: lib/core/sanitizer.ml:1-25, test/test_sanitizer.ml

4. **Observability Foundation**
   - `/metrics` endpoint exposing pool stats (capacity, in_use, waiting, wait_ratio)
   - Load testing script with oha/vegeta support
   - Integration tests for core workflows
   - Evidence: services/api/chessmate_api.ml:278-301, scripts/load_test.sh, test/test_integration.ml

### Notes
- Ensure the opam switch has `caqti` and `caqti-driver-postgresql` installed (`opam install caqti caqti-driver-postgresql`).
- Tests still use `psql` for integration scaffolding; no application code links against libpq anymore.

## 0.5.4 – Parallel PGN Ingest & Embedding chunk tuning

### Added
- Parallel PGN ingestion using Lwt streams and a bounded worker pool (`CHESSMATE_INGEST_CONCURRENCY`), dramatically speeding up large TWIC imports.
- Configurable embedding chunk size (`OPENAI_EMBEDDING_CHUNK_SIZE` / `OPENAI_EMBEDDING_MAX_CHARS`) with per-chunk logging to stay within OpenAI limits.
- Test coverage for chunking helpers (`test/test_embedding_client.ml`).

### Notes
- Tune ingest concurrency based on PGN size and Postgres capacity; the default (4) balances CPU and DB load.
- Monitor worker logs for `[openai-embedding] processed chunk` messages when adjusting embedding chunk limits.

## 0.5.1 – Config Validation & libpq-backed persistence

### Added
- Centralised configuration parsing/validation (`Config` module) with crisp startup errors and `[config]` log summaries for the API and embedding worker.
- Libpq-backed repository implementation replacing the `psql` shell wrapper, enabling parameterised queries and safer SQL throughout.
- Configuration reference and troubleshooting docs covering required/optional environment variables.
- Regression tests for configuration loading scenarios.

### Notes
- Ensure the `postgresql` opam package is installed (`opam install postgresql`).
- Verify service startup logs for `[config]` summaries before running ingest or queries.

## 0.5.0 – Redis Agent Cache & ECO Coverage

### Added
- Redis-backed GPT-5 evaluation cache with env-driven configuration and Docker compose support.
- Expanded agent telemetry (token/cost logging) and caching docs.
- Imported full ECO ranges into `lib/chess/openings.ml` for richer intent recognition.

### Changed
- `.env.sample` reorganized with clearer sections and required `QDRANT_URL` note.
- Architecture documentation refreshed to show Redis/GPT-5 flows.

## 0.4.1 – Ingestion Guard & Parallel Embedding
- Added a configurable `CHESSMATE_MAX_PENDING_EMBEDDINGS` guard to the ingest CLI so bulk imports pause when the embedding queue is saturated.
- Reworked `Repo_postgres`/`embedding_worker` to atomically claim jobs and support `--workers`/`--poll-sleep` flags for safe multi-loop execution.
- Integrated an optional GPT-5 agent: new client wrapper, `reasoning.effort`/verbosity controls, agent-backed scoring in the hybrid executor, and CLI/API output enhancements.
- Documented end-to-end ingestion monitoring with `scripts/embedding_metrics.sh`, pruning utilities, agent configuration, and scaling guidance across README, Operations, and Troubleshooting guides.

## 0.4.0 – Hybrid Query Prototype
- Enhanced `Query_intent` heuristics: opening detection via ECO catalogue, rating/keyword extraction, configurable result limits, and Alcotest coverage.
- Added `lib/chess/openings` (ECO → canonical names/slugs) and persisted `opening_name/opening_slug` through ingestion/migrations.
- Delivered prototype `/query` API (`services/api/chessmate_api.ml`) with curated responses, plus CLI integration (`chessmate query`) configurable via `CHESSMATE_API_URL`.
- Expanded docs (`README`, architecture, operations, developer handbook) with setup guides, API/CLI examples, and mermaid diagrams.
- Updated dependencies (`lwt`, `opium`, `cohttp-lwt-unix`, `uri`), runbook updates, and added migration `0002_add_opening_columns.sql`.

## 0.3.0 – Embedding Pipeline & PGN → FEN
- Introduced `lib/chess/pgn_to_fen` and CLI, moved chess logic into `lib/chess`, and wired `Repo_postgres`/`embedding_worker` for job lifecycle.
- Extended tests/fixtures for FEN generation; documents refreshed for tooling guidance.
- Re-licensed under GPL v3 with notice headers across sources.

## 0.2.0 – Data Ingestion Foundations
- Added migrations/seed scripts, real PGN parser, `chessmate ingest` CLI, and supporting tests/logging.

## 0.1.0 – Scaffolding
- Baseline OCaml project structure, CLI stubs, documentation set, Docker Compose sketch.
