# Release Notes

## 0.3.0 – Milestone 3 (Embedding Pipeline & PGN → FEN)
- Added `lib/chess/pgn_to_fen.ml/.mli`, a standalone engine that parses SAN, maintains board state (castling, en-passant, half/full-move counters) and produces FEN after every half-move.
- Introduced the `pgn_to_fen` CLI (`dune exec pgn_to_fen -- <input.pgn> [output]`) for quick diagnostics and tooling.
- Moved PGN/core helpers (`pgn_parser`, `game_metadata`, `fen`, `position_features`) into `lib/chess/` so all chess-specific logic lives together.
- Wired `Repo_postgres` to the local `psql` client so embedding jobs transition through pending → started → completed/failure states, and extended the `embedding_worker` executable to exercise those hooks end to end.
- Extended tests and fixtures to cover per-ply FEN sequences and new helper functions; updated docs/README with tooling guidance.
- Re-licensed the project under GPL v3, updated metadata, and added notice headers to all sources.

## 0.2.0 – Milestone 2 (Data Ingestion Foundations)
- Introduced PostgreSQL migration and seed scripts (`scripts/migrate.sh`, `scripts/migrations/0001_init.sql`, `scripts/seed_sample_games.sql`) to stand up the relational schema locally.
- Implemented real PGN parsing in `lib/chess/pgn_parser.ml`, handling headers, stripping comments, and extracting SAN moves with ply/turn metadata.
- Expanded Alcotest coverage including disk-backed sample PGN, plus console dumps for debugging.
- Wired `chessmate ingest` to parse PGN files and report counts, laying groundwork for database persistence.

## 0.1.0 – Milestone 1 (Scaffold)
- Scaffolded OCaml library structure with `chess`, `storage`, `embedding`, `query`, and `cli` namespaces; every module ships with `.mli` interfaces and `open! Base` defaults.
- Added placeholder implementations for PGN parsing, FEN helpers, storage adapters, embedding client, query planner, and CLI commands, each returning `Or_error` stubs for now.
- Established Alcotest baseline suite (`test/test_chessmate.ml`) to guard the current parser stub behaviour; wired tests through `dune`.
- Created documentation set: implementation plan, architecture overview, developer handbook, operations playbook, and collaboration guidelines.
- Introduced Docker Compose sketch and data directory layout, ensuring Postgres/Qdrant volumes mount under `data/`.
- Refreshed README with project summary, badges, setup steps, and links to key docs; updated opam metadata to point at the `HendrikReh/chessmate` repository.
