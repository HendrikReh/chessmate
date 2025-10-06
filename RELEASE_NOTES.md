# Release Notes

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
