# Developer Handbook

## Onboarding Checklist
- Install OCaml 5.x, `opam`, and run `opam switch create .` inside the repo (local switch lives under `_opam/`).
- Pull build deps: `opam install . --deps-only --with-test`.
- Confirm Dune works: `dune build`, `dune test`, `dune fmt --check`.
- Start services via `docker-compose up postgres qdrant` when developing ingestion or query code.

## Repository Layout
- `lib/`: OCaml libraries split into `core/`, `storage/`, `embedding/`, `query/`, `cli/`.
- `bin/`: CLI entry points (e.g., `chessmate ingest`, `chessmate query`).
- `test/`: Alcotest suites mirroring module names.
- `docs/`: Architecture, ops, and planning references.
- `data/`: Host-mounted volumes for Postgres (`data/postgres`) and Qdrant (`data/qdrant`).
- `scripts/`: Database migrations, developer utilities.

## Build & Test Workflow
- Format before commits: `dune fmt`.
- Compile and run tests locally: `dune build && dune test`.
- Integration tests (requires Docker): `docker-compose up -d` then `dune test --force`. Shut down with `docker-compose down`.
- Use `WATCH=1 dune runtest` for rapid iteration on a specific suite.

## Development CLI Usage
```
dune exec chessmate -- ingest path/to/game.pgn   # parses PGNs -> Postgres queue
DUNE_PROFILE=release dune exec chessmate -- query "describe queenside majority"  # hybrid search
```

## Coding Standards
- Every `.ml` file starts with `open! Base`; expose API via `.mli`.
- Keep domain logic pure inside `lib/core`; side-effects in `storage/` or service-specific modules.
- Prefer pattern matching and immutable data; avoid partial functions.
- Return `Or_error.t` for recoverable failures; bubble up via CLI error handling.
- Use `[%log]` (once logging added) rather than `Printf.printf` in long-lived services.

## Git Workflow
1. Create feature branch: `git checkout -b feature/<short-description>`.
2. Keep commits focused and imperative (e.g., `feat: add fen normalizer`).
3. Rebase on `main` before pushing; resolve conflicts locally.
4. Open PR with summary, testing commands, rollout notes. Request review from another contributor.

## IDE & Tooling Tips
- VS Code + OCaml Platform extension or Emacs + merlin for type-aware editing.
- Use ocamlformat integration for on-save formatting.
- Install `git hook` (optional script under `scripts/`) to enforce `dune fmt` and tests pre-push.

## Troubleshooting
- Tests failing due to missing services: ensure Docker containers are up and `.env` variables loaded.
- Embedding calls rate-limited: temporarily mock `Embedding_client` with fixtures; record cassettes once VCR-like tests exist.
- Qdrant schema errors: re-run migrations or wipe `data/qdrant` if using disposable dev data.

## Continuous Integration
- Every push and pull request triggers GitHub Actions workflow [`ci.yml`](../.github/workflows/ci.yml).
- Pipeline steps: checkout, OCaml 5.1 setup, dependency install, `dune build`, `dune test`.
- No remote caching configured; run times reflect full builds.
- View results under the GitHub Actions tab. Always ensure your branch is green before requesting review.
- Optional local dry-run: install [`act`](https://github.com/nektos/act) and execute `HOME=$PWD act -j build-and-test -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest --container-architecture linux/amd64`. Some GitHub services (cache, secrets) are unavailable locally, so expect differences.
