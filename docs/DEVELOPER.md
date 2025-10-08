# Developer Handbook

## Onboarding Checklist
1. Copy `.env.sample` to `.env` and update the connection strings/API keys you need locally.
2. Install OCaml 5.1.x and `opam`; create the local switch inside the repo (lives under `_opam/`) and load it per shell with `eval $(opam env --set-switch)`.
3. Install dependencies: `opam install . --deps-only --with-test`.
4. Build/test baseline: `dune build`, `dune runtest`, `dune fmt --check`.
5. Start backing services when needed: `docker compose up -d postgres qdrant` (first run downloads images).
6. Run migrations with a fresh database: `export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate && ./scripts/migrate.sh`.
7. Launch the prototype query API in its own shell: `dune exec chessmate_api -- --port 8080`.
8. Ensure `psql`, Docker (with Compose), and `curl` are available on your `PATH`; set `OPENAI_API_KEY` if you intend to exercise the embedding worker and `AGENT_API_KEY` if you plan to test GPT-5 agent ranking.

## Repository Layout (Top Level)
- `lib/chess/`: PGN/FEN parsing, metadata helpers, ECO catalogue, FEN tooling.
- `lib/storage/`, `lib/embedding/`, `lib/query/`, `lib/cli/`: persistence, embedding clients, query planner, shared CLI modules.
- `bin/`: CLI entry points (`chessmate`).
- `services/`: long-running executables (embedding worker, query API prototype).
- `scripts/`: migrations/seeding helpers.
- `docs/`: architecture, operations, developer, contribution guides.
- `test/`: Alcotest suites + fixtures (`test/fixtures/`).
- `data/`: Docker volumes (`data/postgres`, `data/qdrant`).

## Database & Services
```sh
# bring services up
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
CHESSMATE_API_URL=http://localhost:8080

docker compose up -d postgres qdrant
./scripts/migrate.sh
```
- Drop/reset by removing `data/postgres` and re-running migrations (the script is idempotent).
- Inspect data with `psql "$DATABASE_URL" -c 'SELECT id, opening_slug FROM games;'`.

## Build & Test Workflow
- Formatting: `dune fmt` (run before commits; CI enforces `dune fmt --check`).
- Unit tests: `dune build && dune runtest`.
- Watch mode: `WATCH=1 dune runtest` (re-runs changed suites).
- Stream test output: `dune runtest --no-buffer` (useful for verbose parsers).
- Integration passes: ensure Docker services are running, then `dune runtest --force`.
- Before opening a PR: capture `dune build && dune runtest` output in the PR template.

### CLI Usage Cheatsheet
```sh
# Ingest a PGN (requires DATABASE_URL). Adjust or disable the queue guard via
# CHESSMATE_MAX_PENDING_EMBEDDINGS before bulk imports.
chessmate ingest test/fixtures/extended_sample_game.pgn

# Query prototype API (ensure server runs on localhost:8080)
chessmate query "Show French Defense draws with queenside majority"

# Embedding worker loop (replace OPENAI_API_KEY for real runs)
OPENAI_API_KEY=dummy chessmate embedding-worker --workers 4 --poll-sleep 1.0

# Watch queue depth & throughput every two minutes
DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  scripts/embedding_metrics.sh --interval 120

# Prune stale pending jobs after re-ingest
DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  scripts/prune_pending_jobs.sh 2000

# FEN diagnostics
chessmate fen test/fixtures/sample_game.pgn | head -n 5

# Enable GPT-5 agent ranking (optional)
AGENT_API_KEY=test-key AGENT_REASONING_EFFORT=low AGENT_CACHE_CAPACITY=200 \
  chessmate query "Explain Najdorf exchange sacrifices"
```

### Bulk Ingestion Tips
- Keep `CHESSMATE_MAX_PENDING_EMBEDDINGS` conservative in development (≤ 400k) so runaway queues fail fast.
- Metrics script cadence: 60–120 seconds works well for 5–10 worker loops; shorten to 30 seconds while tuning.
- When throughput plateaus, lower `--workers` or increase `--poll-sleep` before OpenAI throttling kicks in.
- Always prune pending jobs with populated `vector_id`s before re-ingesting the same PGN to avoid duplicates.
- Agent evaluations are optional; unset `AGENT_API_KEY` when running tests offline or use `AGENT_REASONING_EFFORT=low` to reduce cost/latency during development.

- Keep `CHESSMATE_MAX_PENDING_EMBEDDINGS` conservative in development (≤ 400k) so runaway queues fail fast.
- Metrics script cadence: 60–120 seconds works well for 5–10 worker loops; shorten to 30 seconds while tuning.
- When throughput plateaus, lower `--workers` or increase `--poll-sleep` before OpenAI throttling kicks in.
- Always prune pending jobs with populated `vector_id`s before re-ingesting the same PGN to avoid duplicates.

### Parsing PGNs Programmatically
```ocaml
# let raw = Stdio.In_channel.read_all "game.pgn";;
val raw : string = "..."
# match Chessmate.Pgn_parser.parse raw with
  | Ok game -> List.take game.moves 3
  | Error err -> raise_s [%sexp "parse failure", (err : Error.t)]
;;
- : Chessmate.Pgn_parser.move list = [ ... ]

# match Chessmate.Pgn_parser.parse_file "game.pgn" with
  | Ok game -> Chessmate.Game_metadata.of_headers game.headers
  | Error err -> raise_s [%sexp "parse-file failure", (err : Error.t)]
;;
- : Chessmate.Game_metadata.t = { ... }
```

## Coding Standards
- Adopt `open! Base`; expose only required signatures via `.mli`.
- Keep pure logic under `lib/chess`; place side-effects (database, network) in `lib/storage` or service modules.
- Prefer pattern matching, avoid partial functions, return `Or_error.t` for recoverable failures.
- Avoid ad-hoc `printf` in long-lived services—use logging macros once wired in.

## Git Workflow
1. `git checkout -b feature/<descriptor>`.
2. Keep commits focused/imperative (e.g., `feat: add opening catalogue`).
3. Rebase on `main` before pushing; resolve conflicts locally.
4. Open PR with summary, test evidence, rollout notes; request review.

## IDE & Tooling Tips
- Source the opam switch in new shells: `eval $(opam env --set-switch)`.
- Recommended: VS Code + OCaml Platform, or Emacs + merlin; enable ocamlformat-on-save.
- Optional Git hooks under `scripts/` can enforce formatting/tests pre-push.

## Troubleshooting
- Connection errors to Postgres: ensure `docker compose ps` shows containers healthy; confirm `DATABASE_URL`.
- Embedding rate limits: mock `Embedding_client` or throttle job polling; capture fixtures for deterministic tests.
- Qdrant schema mismatches: rerun migrations or wipe `data/qdrant` if working with disposable dev data.
- CLI query returning curated results only: API is still prototype—planner stubs curated data until Qdrant/Postgres integration lands.

## Continuous Integration
- GitHub Actions workflow [`ci.yml`](../.github/workflows/ci.yml) runs on pushes/PRs (build + tests).
- No remote caching: expect full builds; keep dependencies minimal.
- Re-run CI from GitHub Actions tab after rebases/flaky failures; log flakes in an issue.
- Local dry-run (optional): `HOME=$PWD act -j build-and-test -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest --container-architecture linux/amd64` (some GitHub services unavailable locally).

## Related Documentation

- [Chessmate for Dummies](CHESSMATE_FOR_DUMMIES.md) - Complete ingestion and search flow explanation
- [Architecture](ARCHITECTURE.md) - System design, components, and data flow diagrams
- [Operations](OPERATIONS.md) - Deployment, monitoring, and backup procedures
- [LLM Prompts](PROMPTS.md) - Useful prompts for chess analysis and data augmentation
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
- [Guidelines](GUIDELINES.md) - Collaboration standards and PR checklist
