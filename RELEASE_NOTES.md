# Release Notes

## 0.1.0 – Milestone 1 Scaffold
- Scaffolded OCaml library structure with `core`, `storage`, `embedding`, `query`, and `cli` namespaces; every module ships with `.mli` interfaces and `open! Base` defaults.
- Added placeholder implementations for PGN parsing, FEN helpers, storage adapters, embedding client, query planner, and CLI commands, each returning `Or_error` stubs for now.
- Established Alcotest baseline suite (`test/test_chessmate.ml`) to guard the current parser stub behaviour; wired tests through `dune`.
- Created documentation set: implementation plan, architecture overview, developer handbook, operations playbook, and collaboration guidelines.
- Introduced Docker Compose sketch and data directory layout, ensuring Postgres/Qdrant volumes mount under `data/`.
- Refreshed README with project summary, badges, setup steps, and links to key docs; updated opam metadata to point at the `HendrikReh/chessmate` repository.
