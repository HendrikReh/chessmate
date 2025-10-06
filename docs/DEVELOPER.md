# Developer Handbook

## Onboarding Checklist
- Install OCaml 5.x, `opam`, and run `opam switch create .` inside the repo (local switch lives under `_opam/`); load it in each shell with `eval $(opam env --set-switch)`.
- Pull build deps: `opam install . --deps-only --with-test`.
- Confirm Dune works: `dune build`, `dune test`, `dune fmt --check`.
- Start backing services with `docker compose up -d postgres qdrant` when developing ingestion or query code.
- Tooling prerequisites: PostgreSQL client (`psql`) and `curl` must be available for persistence and OpenAI embeddings.

## Repository Layout (Top Level)
- `lib/chess/`: PGN parsing, metadata helpers, and PGN→FEN engine (chess-specific logic).
- `lib/storage/`, `lib/embedding/`, `lib/query/`, `lib/cli/`: persistence, embeddings, planning, and shared CLI utilities.
- `bin/`: CLI entry points (`chessmate`, `pgn_to_fen`, …).
- `services/`: long-running executables such as the embedding worker.
- `test/`: Alcotest suites and fixtures (`test/fixtures/` holds canonical PGNs).
- `docs/`, `scripts/`, `data/`: documentation, migrations, and Docker-mounted volumes.

## Database Setup
- Export `DATABASE_URL` (e.g., `postgres://chess:chess@localhost:5433/chessmate`).
- Run migrations: `./scripts/migrate.sh` (executes files in `scripts/migrations/`).
- Optionally seed sample data for smoke tests: `psql "$DATABASE_URL" -f scripts/seed_sample_games.sql`.

## Build & Test Workflow
- Format before commits: `dune fmt`.
- Compile and run tests locally: `dune build && dune test`.
- Integration tests (requires Docker): `docker compose up -d postgres qdrant` then `dune test --force`. Shut down with `docker compose down`.
- Use `WATCH=1 dune runtest` for rapid iteration on a specific suite.
- Test output tips: Dune captures stdout by default; to stream logs live (e.g., parsed PGN dumps) run `dune test --no-buffer`. Add `--force` if the test target is already built.
- `chessmate` CLI subcommands are still being wired; ingestion/query commands will ship alongside milestone 4. Use the lower-level modules directly in tests for now.
- Embedding worker: run `OPENAI_API_KEY=<key> DATABASE_URL=<postgres-uri> dune exec embedding_worker` to poll the queue. The worker exercises the control loop and persistence hooks; configure Postgres/Qdrant locally to observe end-to-end writes as they land.
- PGN → FEN utility: run `dune exec pgn_to_fen -- <input.pgn> [output.txt]` to emit the FEN after each half-move. Useful for verifying ingestion data and debugging SAN parsing.

## Development CLI Usage
- `dune exec pgn_to_fen -- test/fixtures/sample_game.pgn` – prints FEN strings after every half-move (handy for debugging ingestion states).
- `dune exec embedding_worker` – polls `embedding_jobs` and records vector IDs once Postgres/Qdrant are running.
- CLI wrappers for ingestion and query are tracked for milestone 4 (`docs/IMPLEMENTATION_PLAN.md`).

## Coding Standards
- Every `.ml` file starts with `open! Base`; expose API via `.mli`.
- Keep domain logic pure inside `lib/chess`; route side-effects through `lib/storage` or service-specific modules.
- Prefer pattern matching and immutable data; avoid partial functions.
- Return `Or_error.t` for recoverable failures; bubble up via CLI error handling.
- Use `[%log]` (once logging added) rather than `Printf.printf` in long-lived services.

## Git Workflow
1. Create feature branch: `git checkout -b feature/<short-description>`.
2. Keep commits focused and imperative (e.g., `feat: add fen normalizer`).
3. Rebase on `main` before pushing; resolve conflicts locally.
4. Open PR with summary, testing commands, rollout notes. Request review from another contributor.

## IDE & Tooling Tips
- Set up the correct environment with `eval $(opam env --set-switch)`.
- VS Code + OCaml Platform extension or Emacs + merlin for type-aware editing.
- Use ocamlformat integration for on-save formatting.
- Install `git hook` (optional script under `scripts/`) to enforce `dune fmt` and tests pre-push.

## Troubleshooting
- Tests failing due to missing services: ensure Docker containers are up and `.env` variables loaded.
- Embedding calls rate-limited: temporarily mock `Embedding_client` with fixtures; record cassettes once VCR-like tests exist.
- Qdrant schema errors: re-run migrations or wipe `data/qdrant` if using disposable dev data.

## Continuous Integration
- Every push and pull request triggers GitHub Actions workflow [`ci.yml`](../.github/workflows/ci.yml).
- Pipeline steps: checkout, OCaml toolchain setup, dependency install, `dune build`, `dune test`.
- No remote caching configured; run times reflect full builds.
- View results under the GitHub Actions tab. Always ensure your branch is green before requesting review.
- Optional local dry-run: install [`act`](https://github.com/nektos/act) and execute `HOME=$PWD act -j build-and-test -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest --container-architecture linux/amd64`. Some GitHub services (cache, secrets) are unavailable locally, so expect differences.
