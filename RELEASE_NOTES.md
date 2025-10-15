# Release Notes

## 0.7.0 – Snapshot Tooling & Hybrid Optimisations (2025-10-15)

### Infrastructure & Reliability
- **GH-001** – Fixed the rate limiter race condition by holding the mutex across prune operations and auditing callers.
- **GH-002** – Added `AGENT_REQUEST_TIMEOUT_SECONDS`, wiring timeouts through the GPT-5 client so slow requests fall back to heuristic results with clear warnings.
- **GH-003** – Made the embedding worker batch size configurable (`CHESSMATE_WORKER_BATCH_SIZE`) and surfaced the effective value in logs.
- **GH-004** – Completed the SQL injection audit, ensuring all dynamic queries remain parameterised after the Caqti migration.
- **GH-010** – Expanded Prometheus metrics with per-route latency histograms, error counters, and richer agent telemetry.

### Query & Retrieval
- **GH-040** – Optimised the hybrid executor by caching rating predicates per summary and refactoring keyword tokenisation into a single-pass buffer pipeline.
- **GH-042** – Introduced `chessmate collection snapshot|restore|list`, recording snapshot metadata to `snapshots/qdrant_snapshots.jsonl` and documenting rollback workflow.

### Tooling & Documentation
- **GH-022** – Completed the public module interface sweep, adding missing `.mli` files and standardising GPL headers across the exposed surface.
- Reorganised long-form documentation under `docs/handbook/` and refreshed load-testing and snapshot guidance throughout the handbook and README.

## 0.6.3 – PGN Annotation Support & Agent Polish

### Added
- Annotated PGN fixture plus regression tests covering percent comments, SAN suffixes, and FEN generation.

### Changed
- GPT-5 response handling now reads `output_text` payloads alongside legacy fields, improving compatibility with streamed responses.
- Rate limiter metrics sort per-IP counters for deterministic Prometheus output.
- PGN metadata sanitisation normalises header dates, trims tag whitespace, and ignores annotated SAN suffixes during parsing.

## 0.6.2 – Rate Limiting & Qdrant Bootstrap

### Added
- Per-IP token-bucket rate limiting (`CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE`/`CHESSMATE_RATE_LIMIT_BUCKET_SIZE`) with 429 responses, Prometheus counters, and middleware integration.
- Automatic Qdrant collection bootstrap at API/worker startup (`QDRANT_COLLECTION_NAME`, `QDRANT_VECTOR_SIZE`, `QDRANT_DISTANCE`).

### Changed
- `/metrics` now includes rate-limiter counters.
- Documentation updates covering new env vars and operational workflow.

## 0.6.1 – Health Checks & Query JSON Mode

### Added
- Dependency health checks (Postgres, Qdrant, Redis, API) before `chessmate query` executes.
- `--json` flag to `chessmate query` for raw API responses.

### Fix
- Resolved SQL whitespace bug affecting query pagination defaults.

### Notes
- Refreshed review roadmap (`docs/handbook/REVIEW_v4.md`) and consolidated CLI docs.

## 0.6.0 – Caqti Repository Migration

### Changed
- Replaced libpq wrapper with typed Caqti repository/pool.
- Vector uploads to Qdrant with retry logic and metadata enrichment.
- Secret sanitisation for logs/errors.
- `/metrics` endpoint, load-testing guides, integration tests.
