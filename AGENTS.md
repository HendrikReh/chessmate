# Repository Guidelines

## Prompt execution guideline
Structure any request properly for yourself, then execute it systematically.

## Environment Setup & Tooling
Use the local opam switch stored in `_opam/`. Run `opam switch set .` once per shell so Dune and linters resolve dependencies consistently. Keep OCaml, Dune, and ocamlformat versions in sync with `chessmate.opam`; update that file before introducing new tooling.

## Project Structure & Module Organization
The workspace root contains `dune-project`, `lib/` for reusable chess logic, `bin/` for CLI entry points (`main.ml` today), and `test/` for automated suites. Compiled artifacts land under `_build/`. Place diagrams or write-ups beside the relevant code (for example `lib/board/`), and keep experimental spikes in throwaway branches rather than committing them.

## Build, Test, and Development Commands
- `opam install . --deps-only --with-test`: install and refresh dependencies declared in `chessmate.opam`.
- `dune build`: compile all libraries and executables from the repository root.
- `dune exec bin/main.exe`: run the CLI manually while iterating.
- `dune test`: execute suites defined under `test/` and report Alcotest output.
- `dune fmt`: format all OCaml sources with the repo’s ocamlformat profile.

## Coding Style & Naming Conventions
Stick to two-space indentation, no tabs, and wrap lines at roughly 100 characters. Modules and files use `UpperCamelCase` (`BoardState.ml`), functions and values use `lower_snake_case`, and variant constructors stay in `PascalCase`. Keep pure rules in `lib/`; quarantine IO or CLI parsing in `bin/`. Always run `dune fmt` before staging changes.

## Testing Guidelines
Author Alcotest suites in `test/`, mirroring module names (`board_state.ml` → `test_board_state.ml`). Group cases with `Alcotest.test_case` and aggregate them in a central `run` invocation. Update `test/dune` with new libraries whenever a suite gains dependencies. Aim to cover move generation, validation, and CLI interactions; run `dune test` before every push.

## Commit & Pull Request Guidelines
Write imperative commit subjects with an optional scope (`feat: add move parser`). When a change impacts behavior, include brief body lines about rationale and validation commands. Pull requests should link related issues, call out breaking changes, and attach CLI output or screenshots if user-facing behavior shifts. Document follow-up work in the PR description rather than burying it in comments.
