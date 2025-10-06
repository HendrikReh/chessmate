# Chessmate

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.1-orange.svg)](https://ocaml.org)
[![Version](https://img.shields.io/badge/Version-0.2.0-blue.svg)](RELEASE_NOTES.md)
[![Status](https://img.shields.io/badge/Status-Proof%20of%20Concept-yellow.svg)](docs/IMPLEMENTATION_PLAN.md)
[![Build Status](https://img.shields.io/github/actions/workflow/status/HendrikReh/chessmate/ci.yml?branch=main)](https://github.com/HendrikReh/chessmate/actions)
[![License](https://img.shields.io/github/license/HendrikReh/chessmate)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](docs/GUIDELINES.md)
[![Collaboration](https://img.shields.io/badge/Collaboration-Guidelines-blue.svg)](docs/GUIDELINES.md)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-active-green.svg)](https://github.com/HendrikReh/chessmate/graphs/commit-activity)

Self-hosted chess tutor that blends relational data (PostgreSQL) with vector search (Qdrant) to answer natural-language questions about ~4k annotated games. OCaml powers ingestion, hybrid retrieval, and CLI tooling.

## Requirements
- PostgreSQL client (`psql`) available on the `PATH` for running migrations and database writes.
- `curl` (used by the embedding worker to call the OpenAI API).

## Features
- **Hybrid search:** combine OpenAI FEN embeddings with keyword filters for precise tactics or opening questions.
- **Structured metadata:** Postgres schema stores games, players, positions, and annotations with ECO tags and ratings.
- **CLI-first UX:** `chessmate ingest` for PGN ingestion, `chessmate query` to explore positions via natural language.
- **Extensible architecture:** modular OCaml library (core/storage/embedding/query) plus an embedding worker scaffold for background vector sync.

## Getting Started
1. Clone and enter the repository.
2. Create an opam switch and install dependencies:
   ```sh
   opam switch create . 5.1.0
   opam install . --deps-only --with-test
   ```
3. Launch backing services (Postgres, Qdrant) via Docker:
   ```sh
   docker-compose up -d postgres qdrant
   ```
4. Build and run tests:
   ```sh
   dune build
   dune test
   ```
5. Try the CLI stubs and worker loop:
   ```sh
   dune exec chessmate -- ingest fixtures/sample.pgn
   dune exec chessmate -- query "Find games with a queenside majority attack"
   OPENAI_API_KEY=dummy DATABASE_URL=postgres://... dune exec embedding_worker
   ```

## Repository Structure
```
lib/            # Core OCaml libraries (core, storage, embedding, query, cli)
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
Distributed under the [MIT License](LICENSE).
