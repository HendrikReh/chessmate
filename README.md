# Chessmate

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.1-orange.svg)](https://ocaml.org)
[![Version](https://img.shields.io/badge/Version-0.3.0-blue.svg)](RELEASE_NOTES.md)
[![Status](https://img.shields.io/badge/Status-Proof%20of%20Concept-yellow.svg)](docs/IMPLEMENTATION_PLAN.md)
[![Build Status](https://img.shields.io/github/actions/workflow/status/HendrikReh/chessmate/ci.yml?branch=main)](https://github.com/HendrikReh/chessmate/actions)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](docs/GUIDELINES.md)
[![Collaboration](https://img.shields.io/badge/Collaboration-Guidelines-blue.svg)](docs/GUIDELINES.md)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-active-green.svg)](https://github.com/HendrikReh/chessmate/graphs/commit-activity)

Self-hosted chess tutor that blends relational data (PostgreSQL) with vector search (Qdrant) to answer natural-language questions about ~4k annotated games. OCaml powers ingestion, hybrid retrieval, and CLI tooling.

## Requirements
- PostgreSQL client (`psql`) available on the `PATH` for running migrations and database writes.
- `curl` (used by the embedding worker to call the OpenAI API).

## Feature Highlights
- **PGN ingestion pipeline:** parse headers/SAN, derive per-ply FEN snapshots, and persist metadata for downstream services.
- **Embedding worker skeleton:** polls `embedding_jobs`, calls OpenAI embeddings, and records vector identifiers ready for Qdrant sync.
- **Structured module layout:** chess logic under `lib/chess`, persistence in `lib/storage`, embeddings in `lib/embedding`, query planning under `lib/query`, and CLI glue in `lib/cli`.
- **PGN → FEN tooling:** `dune exec pgn_to_fen -- <game.pgn>` prints the FEN after each half-move for quick analysis.
- **Road to hybrid search:** milestone 4 will wire intent parsing, hybrid planning, and the HTTP query API (`docs/IMPLEMENTATION_PLAN.md`).

## Getting Started
1. Clone and enter the repository.
2. Create an opam switch and install dependencies:
   ```sh
   opam switch create . 5.1.0
   opam install . --deps-only --with-test
   ```
3. Launch backing services (Postgres, Qdrant) via Docker:
   ```sh
   docker compose up -d postgres qdrant
   ```
4. Build and run tests:
   ```sh
   dune build
   dune test
   ```
5. Explore the available tooling:
   ```sh
   OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec embedding_worker
   dune exec pgn_to_fen -- test/fixtures/sample_game.pgn
   ```
   The `chessmate` CLI entrypoint is a work in progress; ingestion and query commands will land with milestone 4.

## Repository Structure
```
lib/            # OCaml libraries (chess, storage, embedding, query, cli)
bin/            # CLI entry points
scripts/        # Database migrations (`migrate.sh`, `migrations/`, seeds)
services/       # Long-running services (e.g., embedding_worker)
docs/           # Architecture, developer, ops, and planning docs
test/           # Alcotest suites
data/           # Bind-mounted volumes for Postgres and Qdrant
```

## Documentation
- [Implementation Plan](docs/IMPLEMENTATION_PLAN.md)
- [Architecture Overview](docs/ARCHITECTURE.md)
- [Developer Handbook](docs/DEVELOPER.md)
- [Operations Playbook](docs/OPERATIONS.md)
- [Collaboration Guidelines](docs/GUIDELINES.md)

## Contributing
PRs welcome! See [Collaboration Guidelines](docs/GUIDELINES.md) for coding standards, testing expectations, and PR checklist. Please open an issue before large changes and include `dune build && dune test` output in your PR template.

## License
Distributed under the [GNU General Public License v3.0](LICENSE).
