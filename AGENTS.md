# Repository Guidelines

## Prompt Execution Guideline
Always restate the user task for yourself, outline the intended steps, then execute systematically. This keeps chronology clear and avoids missed requirements.

## Environment Setup & Tooling
- Use the local opam switch stored in `_opam/`. Run `eval $(opam env --set-switch)` (or `opam switch create .`) in each shell so Dune and linters resolve dependencies consistently.
- `psql` and `curl` must be available on the `PATH` (used by migration scripts and the embedding worker).
- Keep OCaml, Dune, ocamlformat, and tooling versions aligned with `chessmate.opam` before introducing new dependencies.

- `docs/*.mld`: odoc pages for architecture/CLI/services; keep them updated alongside Markdown docs.
## Project Structure Highlights
- `lib/chess/`: PGN parsing, metadata helpers, and PGN→FEN engine.
- `lib/storage/`, `lib/embedding/`, `lib/query/`, `lib/cli/`: persistence, embeddings, planning, and shared CLI code.
- `bin/`: CLI entry points (`chessmate`, plus legacy `pgn_to_fen`).
- `services/`: long-running executables (embedding worker, API prototype).
- `test/fixtures/`: canonical PGN fixtures used by tests.

## Core Commands
- `opam install . --deps-only --with-test`
- `dune build`
- `dune runtest` (use `--no-buffer` to stream PGN/FEN logs)
- `dune exec chessmate -- ingest …`, `dune exec chessmate -- query …` (set `CHESSMATE_API_URL` when targeting a non-default port)
- `chessmate fen <game.pgn>` for quick FEN verification.

## Coding Style & Etiquette
- Two-space indentation, `open! Base` at the top of `.ml` files, explicit `.mli` signatures.
- **Functional-first mindset**: write pure functions where possible, avoid mutation, return `Or_error.t` for recoverable failures.
- Keep chess domain logic pure in `lib/chess/`; isolate side effects (IO, DB, network) in CLI/services.
- Use pattern matching, higher-order helpers (e.g., `List.map`, `Option.bind`), and avoid partial functions.
- Run `dune fmt` (ocamlformat profile `conventional`, version `0.27.0`) before staging changes; include `dune build && dune runtest` output in PR descriptions.

## Testing Discipline
- Mirror library modules with Alcotest suites under `test/` and register them via `Alcotest.run`.
- Update `test/dune` when new fixtures or libraries are required.
- Prefer deterministic fixtures (see `test/fixtures/`) and print diagnostics only when helpful (`--no-buffer`).

## Commit & PR Guidelines
- Imperative branch/commit subjects (e.g., `feat: add pgn fen helper`).
- Link related issues in PRs, summarize behaviour changes, list validation commands, and highlight user-visible output when relevant.
- Document follow-up work in the PR description rather than ad-hoc comments.
