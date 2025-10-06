# Repository Guidelines

## Prompt Execution Guideline
Always restate the user task for yourself, outline the intended steps, then execute systematically. This keeps chronology clear and avoids missed requirements.

## Environment Setup & Tooling
- Use the local opam switch stored in `_opam/`. Run `eval $(opam env --set-switch)` (or `opam switch create .`) in each shell so Dune and linters resolve dependencies consistently.
- `psql` and `curl` must be available on the `PATH` (used by migration scripts and the embedding worker).
- Keep OCaml, Dune, and ocamlformat versions aligned with `chessmate.opam` before introducing new tooling.

## Project Structure Highlights
- `lib/chess/`: PGN parsing, metadata helpers, and PGN→FEN engine (new home for all chess-specific modules).
- `lib/storage/`, `lib/embedding/`, `lib/query/`, `lib/cli/`: persistence, embeddings, planning, and shared CLI code.
- `bin/`: CLI entry points (`chessmate`, plus legacy `pgn_to_fen`).
- `services/`: long-running executables such as the embedding worker.
- `test/fixtures/`: canonical PGN fixtures used by tests.

## Core Commands
- `opam install . --deps-only --with-test`
- `dune build`
- `dune test` (use `--no-buffer` to stream PGN/FEN logs)
- `dune exec chessmate -- ingest …`, `dune exec chessmate -- query …` (set `CHESSMATE_API_URL` when targeting a non-default port)
- `chessmate fen <game.pgn>` for quick FEN verification.

## Coding Style & Etiquette
- Two-space indentation, `open! Base` at the top of `.ml` files, and explicit `.mli` signatures.
- Keep pure chess logic in `lib/chess/`; isolate side effects in CLI/services.
- Run `dune fmt` before staging changes; include `dune build && dune test` output in PR descriptions.

## Testing Discipline
- Mirror library modules with Alcotest suites under `test/` and register them via `Alcotest.run`.
- Update `test/dune` when new fixtures or libraries are required.
- Prefer deterministic fixtures (see `test/fixtures/`) and print diagnostics only behind `--no-buffer` recommendations.

## Commit & PR Guidelines
- Imperative branch/commit subjects (e.g., `feat: add pgn fen helper`).
- Link related issues in PRs, summarize behavior changes, list validation commands, and highlight user-visible output when relevant.
- Document follow-up work in the PR description rather than ad-hoc comments.
