# Release Notes

## 0.2.0 – Milestone 2 (Data Ingestion Foundations)
- Introduced PostgreSQL migration and seed scripts (`scripts/migrate.sh`, `scripts/migrations/0001_init.sql`, `scripts/seed_sample_games.sql`) to stand up the relational schema locally.
- Implemented real PGN parsing in `lib/core/pgn_parser.ml`, handling headers, stripping comments, and extracting SAN moves with ply/turn metadata.
- Expanded Alcotest coverage including disk-backed sample PGN, plus console dumps for debugging.
- Wired `chessmate ingest` to parse PGN files and report counts, laying groundwork for database persistence.

## 0.1.0 – Milestone 1 (Scaffold)
- Scaffolded OCaml library structure with `core`, `storage`, `embedding`, `query`, and `cli` namespaces; every module ships with `.mli` interfaces and `open! Base` defaults.
- Added placeholder implementations for PGN parsing, FEN helpers, storage adapters, embedding client, query planner, and CLI commands, each returning `Or_error` stubs for now.
- Established Alcotest baseline suite (`test/test_chessmate.ml`) to guard the current parser stub behaviour; wired tests through `dune`.
- Created documentation set: implementation plan, architecture overview, developer handbook, operations playbook, and collaboration guidelines.
- Introduced Docker Compose sketch and data directory layout, ensuring Postgres/Qdrant volumes mount under `data/`.
- Refreshed README with project summary, badges, setup steps, and links to key docs; updated opam metadata to point at the `HendrikReh/chessmate` repository.
