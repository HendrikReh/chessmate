# Release Notes

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
- Refreshed review roadmap (`docs/REVIEW_v4.md`) and consolidated CLI docs.

## 0.6.0 – Caqti Repository Migration

### Changed
- Replaced libpq wrapper with typed Caqti repository/pool.
- Vector uploads to Qdrant with retry logic and metadata enrichment.
- Secret sanitisation for logs/errors.
- `/metrics` endpoint, load-testing guides, integration tests.
