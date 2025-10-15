# Chessmate

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.1-orange.svg)](https://ocaml.org)
[![Version](https://img.shields.io/badge/Version-0.7.0-blue.svg)](RELEASE_NOTES.md)
[![Status](https://img.shields.io/badge/Status-Proof%20of%20Concept-yellow.svg)](docs/IMPLEMENTATION_PLAN.md)
[![Build Status](https://img.shields.io/github/actions/workflow/status/HendrikReh/chessmate/ci.yml?branch=master)](https://github.com/HendrikReh/chessmate/actions)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![GitHub Issues](https://img.shields.io/github/issues/HendrikReh/chessmate)](https://github.com/HendrikReh/chessmate/issues)
[![GitHub Pull Requests](https://img.shields.io/github/issues-pr/HendrikReh/chessmate)](https://github.com/HendrikReh/chessmate/pulls)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](docs/handbook/GUIDELINES.md)
[![Collaboration](https://img.shields.io/badge/Collaboration-Guidelines-blue.svg)](docs/handbook/GUIDELINES.md)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-active-green.svg)](https://github.com/HendrikReh/chessmate/graphs/commit-activity)

Self-hosted chess tutor that blends relational data (PostgreSQL) with vector search (Qdrant) to answer natural-language questions about annotated chess games. OCaml powers ingestion, hybrid retrieval, and CLI tooling.

## Requirements
- OCaml ≥ 5.1 (opam-managed switch) and Dune ≥ 3.20.
- Docker & Docker Compose (brings up Postgres, Qdrant, Redis).
- `psql` CLI (migrations/ingest) and `curl` for health checks.
- `.env` derived from `.env.sample` — set `DATABASE_URL`, `QDRANT_URL`, and optionally `AGENT_*` / `OPENAI_API_KEY`.
- Redis (local Docker service) when GPT-5 agent caching is enabled.
- Optional: [`oha`](https://github.com/hatoo/oha) or `vegeta` for load testing via `scripts/load_test.sh`.

## Feature Highlights
- **Turnkey ingestion & queue safeguards:** parse PGNs into FEN snapshots, persist metadata via Caqti, and keep the embedding queue in check with `CHESSMATE_MAX_PENDING_EMBEDDINGS`.
- **Deterministic + vector search:** analyse intent, merge Postgres and Qdrant hits, and reuse cached rating checks for faster hybrid execution; fall back gracefully when vector search is unavailable.
- **Agent scoring with guardrails:** optionally re-rank results with GPT‑5, honour reasoning/verbosity knobs, enforce request timeouts, and log structured telemetry (latency, tokens, cost).
- **Snapshot-aware operations:** `chessmate collection snapshot|restore|list` wraps Qdrant’s snapshot API, journals metadata locally, and enables repeatable reindex/rollback workflows.
- **Observability & load harness:** rich Prometheus metrics (latencies, rate limiter, agent counters), optional standalone exporters for the CLI/worker (`--listen-prometheus`), a smarter `scripts/load_test.sh` (auto-detect flags, JSON payload minification, Docker stats), and CLI health checks for rapid triage.
- **Docs & tooling:** extensive handbook under `docs/handbook/`, cookbook recipes, runbooks, and odoc pages to keep architecture, operations, and CLI guidance in sync.

## Getting Started
1. Clone and enter the repository.
2. Copy `.env.sample` to `.env` and adjust the environment variables (see comments inside the file).
3. Run the automated bootstrap (optional but recommended):
   ```sh
   ./bootstrap.sh
   ```
   The script creates `.env` (if missing), initialises the opam switch, installs dependencies, starts Docker services, runs migrations, and executes `dune build && dune runtest`. Re-run it anytime you need to resynchronise your workspace.
4. Create an opam switch and install dependencies (skip if `./bootstrap.sh` already did this):
   ```sh
   opam switch create . 5.1.0
   opam install . --deps-only --with-test
   ```
5. Launch backing services (Postgres, Qdrant) via Docker (first run may take a minute while images download):
   ```sh
    docker compose up -d postgres qdrant redis
   ```
6. Initialize the database (migrations expect `DATABASE_URL` to be set):
   ```sh
   # Example connection string; adjust credentials/port if you changed docker-compose.yml
   export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
   ./scripts/migrate.sh
   ```
7. Build & test the workspace:
   ```sh
   dune build
   dune runtest
   ```
   To include the integration suite, provide `CHESSMATE_TEST_DATABASE_URL` (a Postgres connection string with `CREATEDB`) and rerun `dune exec -- test/test_main.exe -- test integration`. See `docs/handbook/TESTING.md` for the full testing matrix.
8. Validate configuration and dependencies:
   ```sh
   dune exec -- chessmate -- config
   ```
   Exit code `0` means all required services/env vars are ready, `2` signals optional components are skipped (e.g. Redis), and `1` indicates a fatal misconfiguration (the command prints remediation hints). Invalid overrides (e.g. non-positive `OPENAI_RETRY_MAX_ATTEMPTS` or `OPENAI_EMBEDDING_CHUNK_SIZE`) are surfaced here. Configure chunking via `OPENAI_EMBEDDING_CHUNK_SIZE` and `OPENAI_EMBEDDING_MAX_CHARS`.
9. Explore the available tooling:
   ```sh
   # Start the prototype query API (Opium server)
   dune exec -- chessmate-api --port 8080
   
   # In another shell, call the API via the CLI (set CHESSMATE_API_URL if you changed the port)
   CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Find King's Indian games where White is 2500 and Black 100 points lower"

   # Ingest a PGN (persists players/games/positions/openings). The CLI aborts if the
   # embedding queue already exceeds CHESSMATE_MAX_PENDING_EMBEDDINGS (default 250k).
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec -- chessmate -- ingest test/fixtures/extended_sample_game.pgn

   # Run the embedding worker loop (requires OPENAI_API_KEY for real embeddings)
   OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     dune exec -- embedding_worker -- --workers 2 --poll-sleep 1.5

   # Enable GPT-5 agent ranking (optional)
   AGENT_API_KEY=dummy-agents-key AGENT_REASONING_EFFORT=high AGENT_CACHE_REDIS_URL=redis://localhost:6379/0 \
     DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec -- chessmate -- query "Find attacking King's Indian games"

   # Generate FENs from a PGN for quick inspection
   dune exec -- chessmate -- fen test/fixtures/sample_game.pgn
   ```

## Repository Structure
```
lib/            # OCaml libraries (chess, storage, embedding, query, cli)
bin/            # CLI entry points
scripts/        # Database migrations (`migrate.sh`, `migrations/`, seeds)
services/       # Long-running services (e.g., embedding_worker)
docs/handbook/  # Architecture, developer, ops, and planning docs
test/           # Alcotest suites
data/           # Bind-mounted volumes for Postgres, Qdrant, and Redis
```

## Services & CLIs
- `dune exec -- chessmate_api -- --port 8080`: starts the prototype query HTTP API.
- `dune exec -- chessmate -- config`: runs dependency/configuration diagnostics (exit codes: `0` OK, `2` warnings for optional components, `1` fatal error).
- `dune exec -- chessmate -- ingest <pgn>`: parses and persists PGNs with parallel parsing (default 4 workers, set `CHESSMATE_INGEST_CONCURRENCY` to tune).
- `dune exec -- chessmate -- twic-precheck <pgn>`: scans TWIC PGNs for malformed entries before ingestion.
- `dune exec -- chessmate -- query "…"`: sends questions to the running query API (`CHESSMATE_API_URL` defaults to `http://localhost:8080`).
- `dune exec -- chessmate -- fen <pgn> [output]`: prints FEN after each half-move (optional output file).
- `OPENAI_API_KEY=… dune exec -- embedding_worker -- [--workers N] [--poll-sleep SECONDS]`: polls `embedding_jobs`, calls OpenAI, updates vector IDs. Use `--workers` to run multiple concurrent loops safely.

### Operational Scripts
- `scripts/embedding_metrics.sh [--interval N] [--log path]`: report queue depth, recent throughput, and ETA for draining pending jobs.
- `scripts/prune_pending_jobs.sh [batch_size]`: mark pending jobs whose positions already have vectors as completed (useful after re-ingest).

### Ingestion & Queue Monitoring
1. Set an appropriate guard before heavy ingest runs:
   ```sh
   # Limit pending jobs to 400k before the CLI aborts (0 disables the guard)
   export CHESSMATE_MAX_PENDING_EMBEDDINGS=400000
   ```
2. Kick off ingest as usual; the command aborts early once the guard threshold is reached.
3. In a separate shell, stream queue metrics every couple of minutes and log them for later analysis:
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     scripts/embedding_metrics.sh --interval 120 --log logs/embedding-metrics.log
   ```
   Sample output:
   ```
   [2025-10-08T06:41:09Z] embedding jobs snapshot
     total        : 756744
     pending      : 607083
     in_progress  : 2
     completed    : 149601
     failed       : 58
     throughput/min (5m | 15m | 60m): 0 | 60.40 | 88.88
     pending ETA  : 10051 minutes (~167.5 hours) based on 15m rate
   ```
4. Keep the embedding worker ahead of the queue:
   ```sh
   OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     dune exec -- embedding_worker -- --workers 4 --poll-sleep 1.0
   ```
   Increase or reduce `--workers` based on the metrics output; look for falling `pending` and steady throughput.
5. Keep the GPT-5 agent (if enabled) supplied with fresh vectors:
   ```sh
   AGENT_API_KEY=real-key AGENT_REASONING_EFFORT=medium \
     DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Explain thematic rook sacrifices"
   ```
   Agent responses include explanations, detected themes, and token usage in the API/CLI output.
6. If the guard triggers or throughput drops unexpectedly, prune stale work before resuming:
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     scripts/prune_pending_jobs.sh 2000
   ```

### Load Testing
- Ensure the API is running (`http://localhost:8080` by default) and that you have ingested a representative data set.
- Install a lightweight HTTP benchmarker such as [`oha`](https://github.com/hatoo/oha) or `vegeta` (the harness checks `TOOL` and falls back automatically).
- Run a short burst (60 seconds, 50 concurrent clients by default):
  ```sh
  TOOL=oha DURATION=60s CONCURRENCY=50 TARGET_URL=http://localhost:8080/query \
    scripts/load_test.sh
  ```
- The script detects whether your `oha` build supports long-form flags, minifies the JSON payload once (handling the `@payload` pitfall), and resolves running Docker Compose container IDs before calling `docker stats`. After the run it prints the `/metrics` payload for quick inspection.
- Watch `db_pool_wait_ratio`, `api_request_latency_ms_p95{route="..."}`, `agent_cache_hits_total`, and embedding throughput gauges. Healthy runs keep wait ratio near zero and p95 latency within expectations—use the values to decide whether to scale Postgres/Qdrant or tweak concurrency. See `docs/handbook/TESTING.md` for extended guidance and troubleshooting.

### Prometheus Metrics
- **API service:** `/metrics` is served from the main Opium process (default `http://localhost:8080/metrics`). The payload includes HTTP latency histograms, Postgres pool gauges, rate-limiter counters, and agent-derived telemetry.
- **CLI commands:** pass `--listen-prometheus=<port>` (or export `CHESSMATE_PROM_PORT`) before the sub-command and the exporter will stream metrics at `http://localhost:<port>/metrics` for the lifetime of the run. Example:
  ```sh
  DATABASE_URL=postgres://... dune exec -- chessmate -- --listen-prometheus=9101 ingest data/sample.pgn
  # scrape http://localhost:9101/metrics while ingest is running
  ```
- **Embedding worker:** enable the exporter via `--listen-prometheus <port>` or `CHESSMATE_WORKER_PROM_PORT`. Metrics cover queue depth, throughput, failure counts, and FEN character volume.
  ```sh
  OPENAI_API_KEY=... DATABASE_URL=postgres://... \
    dune exec -- embedding_worker -- --listen-prometheus 9102 --workers 4
  ```
- **Runtime events (evaluation):** OCaml 5's runtime-events API can emit fine-grained GC and allocation telemetry, but feeding those counters directly into Prometheus would require a dedicated consumer loop polling the per-domain ring buffers. We tested the APIs and deferred automation for now. You can still capture traces manually by launching processes with `OCAML_RUNTIME_EVENTS_START=1` (and optionally `OCAML_RUNTIME_EVENTS_DIR=/tmp/events`) and analysing the resulting `*.events` files with external tooling; the in-process exporters already publish standard GC metrics via `prometheus-app`.
- **Recommended scrape config:**
  ```yaml
  scrape_configs:
    - job_name: chessmate-api
      static_configs:
        - targets: ['localhost:8080']
          labels: {role: api}

    - job_name: chessmate-cli
      static_configs:
        - targets: ['localhost:9101']
          labels: {role: cli-ingest}

    - job_name: chessmate-worker
      static_configs:
        - targets: ['localhost:9102']
          labels: {role: worker}
  ```
  Adjust ports to match your deployment (for example, when running in Docker Compose expose the exporter via `ports:` or a `hostPort`). Pair these scrape jobs with alerting on `db_pool_wait_ratio`, request latency histograms, embedding queue depth, and worker failure counters.

### Agent Configuration
- `AGENT_API_KEY`: required to enable GPT-5 ranking (absent → agent disabled).
- `AGENT_MODEL`: optional, defaults to `gpt-5` (also supports `gpt-5-mini`, `gpt-5-nano`).
- `AGENT_REASONING_EFFORT`: one of `minimal|low|medium|high`; defaults to `medium`.
- `AGENT_VERBOSITY`: `low|medium|high` (choose higher values for verbose reports).
- `AGENT_REQUEST_TIMEOUT_SECONDS`: optional positive float (seconds); defaults to `15` to bound agent latency.
- `AGENT_ENDPOINT`: override the OpenAI Responses API endpoint (advanced setups).
- `AGENT_CACHE_REDIS_URL`: optional `redis://` URL to persist GPT-5 evaluations (requires the Redis service in `docker-compose`).
- `AGENT_CACHE_REDIS_NAMESPACE`: optional key namespace (defaults to `chessmate:agent:` when unset).
- `AGENT_CACHE_TTL_SECONDS`: optional positive integer TTL for Redis entries (omit to keep cached values indefinitely).
- `AGENT_CACHE_CAPACITY`: fallback in-memory cache size (positive integer) when Redis is unavailable or intentionally disabled.
- `AGENT_COST_INPUT_PER_1K`, `AGENT_COST_OUTPUT_PER_1K`, `AGENT_COST_REASONING_PER_1K`: optional USD rates that power telemetry cost estimates (set per 1K tokens; unset → costs omitted).

When any of these variables change, restart API/CLI sessions so the lazy client picks up the new configuration. The API/CLI prints telemetry lines prefixed with `[agent-telemetry]` containing the sanitized question, candidate counts, latency, token usage, and any cost estimates.

### Embedding Worker Configuration
- `OPENAI_EMBEDDING_ENDPOINT`: optional override for the embeddings API endpoint (defaults to `https://api.openai.com/v1/embeddings`).
- `CHESSMATE_WORKER_BATCH_SIZE`: optional positive integer controlling how many jobs the worker claims per poll (defaults to `16`). Use lower values to reduce peak load or higher values to improve throughput when resources allow.
- `CHESSMATE_WORKER_PROM_PORT`: optional TCP port that exposes the worker's Prometheus exporter (identical to passing `--listen-prometheus`).

### CLI Usage
Example CLI session (assuming Postgres is running locally):
```sh
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
CHESSMATE_API_URL=http://localhost:8080

# Ingest a PGN (guarded by CHESSMATE_MAX_PENDING_EMBEDDINGS)
dune exec -- chessmate -- ingest test/fixtures/extended_sample_game.pgn
# => Stored game 1 with 77 positions
# If the embedding queue already exceeds the guard, the command aborts early.
# Set CHESSMATE_MAX_PENDING_EMBEDDINGS=0 (or a higher integer) to adjust the limit.

# Ask a question (make sure the API is running in another shell)
dune exec -- chessmate -- query "Show French Defense draws with queenside majority endings"
# => Summary, filters, and curated results printed to stdout

# Need metrics during long-running commands? Prefix with `--listen-prometheus <port>` (or set `CHESSMATE_PROM_PORT`) and scrape `http://localhost:<port>/metrics` while the command runs.

# Generate FENs (stdout, filtered, file output)
dune exec -- chessmate -- fen test/fixtures/sample_game.pgn
dune exec -- chessmate -- fen test/fixtures/sample_game.pgn | head -n 5
dune exec -- chessmate -- fen test/fixtures/sample_game.pgn /tmp/fens.txt

# Show plan as JSON
dune exec -- chessmate -- query --json "Find King's Indian games" | jq '.'

# Batch ingest PGNs (simple shell loop)
for pgn in fixtures/*.pgn; do
  dune exec -- chessmate -- ingest "$pgn"
done
```

### Example Query Session
After loading a larger event (e.g. TWIC bulletin), the CLI can surface random games or specific openings. The transcript below comes from a live session:

```sh
$ dune exec -- chessmate -- query "Show me 5 random games"
Summary: #3954 Smolik,Jachym vs Yurovskykh,Oleksandr (score 0.42)
#3953 Prokofiev,Valentyn vs Prazak,Daniel (score 0.42)
#3952 Velicka,P vs Haring,Filip (score 0.42)
#3951 Rasik,V vs Akshat Sureka (score 0.42)
#3950 Mayank,Chakraborty vs Cvek,R (score 0.42)
Limit: 5
Filters: No structured filters detected
Ratings: none
Results:
1. #3954 Smolik,Jachym vs Yurovskykh,Oleksandr [English opening] score 0.42
       Smolik,Jachym vs Yurovskykh,Oleksandr — 3rd Gambit GM Closed 2025 (1/2-1/2)
2. #3953 Prokofiev,Valentyn vs Prazak,Daniel [QGD Slav] score 0.42
       Prokofiev,Valentyn vs Prazak,Daniel — 3rd Gambit GM Closed 2025 (1-0)
...

$ dune exec -- chessmate -- query "Show me games in the English opening (5 max)"
Summary: #3954 Smolik,Jachym vs Yurovskykh,Oleksandr (score 0.90)
#420 Smolik,Jachym vs Yurovskykh,Oleksandr (score 0.90)
#106 Smolik,Jachym vs Yurovskykh,Oleksandr (score 0.90)
#8138 Sarno,S vs Montorsi,Matteo (score 0.90)
#8132 Lumachi,Gabriele vs Fedorchuk,S (score 0.90)
Limit: 5
Filters: eco_range=A10-A39, opening=english_opening
Ratings: none
Results:
1. #3954 Smolik,Jachym vs Yurovskykh,Oleksandr [English opening] score 0.90
       Smolik,Jachym vs Yurovskykh,Oleksandr — 3rd Gambit GM Closed 2025 (1/2-1/2)
...
```

These logs demonstrate how the planner surfaces structured filters (ECO ranges, openings) and how the result list shifts once the database contains relevant games.

```sh
OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  dune exec -- embedding_worker -- --workers 2 --poll-sleep 1.5
# [worker] starting polling loop
# [worker] job 42 completed

# In another shell, watch queue depth and ETA every 10 minutes
DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  scripts/embedding_metrics.sh --interval 600
```

FEN tooling for sanity checks:
```sh
dune exec -- chessmate -- fen test/fixtures/sample_game.pgn | head -n 5
# rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1
# rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2
# ...
```

## API Examples
### GET
```sh
curl "http://localhost:8080/query?q=Find+King%27s+Indian+games+where+white+is+2500"
```

### POST
```sh
curl -X POST http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"question": "Show five French Defense endgames that end in a draw"}'
```

Typical JSON response:
```json
{
  "question": "show five french defense endgames that end in a draw",
  "plan": {
    "cleaned_text": "show five french defense endgames that end in a draw",
    "limit": 5,
    "filters": [
      { "field": "opening", "value": "french_defense" },
      { "field": "eco_range", "value": "C00-C19" },
      { "field": "phase", "value": "endgame" },
      { "field": "result", "value": "1/2-1/2" }
    ],
    "keywords": ["french", "defense", "endgames", "draw" ],
    "rating": { "white_min": null, "black_min": null, "max_rating_delta": null }
  },
  "summary": "Found 3 curated matches for the requested opening and result.",
  "results": [
    {
      "game_id": 1,
      "white": "Judith Polgar",
      "black": "Alexei Shirov",
      "result": "1/2-1/2",
      "year": 1997,
      "event": "Linares",
      "opening": "french_defense",
      "score": 0.82,
      "vector_score": 0.74,
      "keyword_score": 0.60,
      "synopsis": "Polgar steers the French Tarrasch into an endgame where a queenside majority holds the draw."
    }
  ]
}
```

### Metrics
```sh
curl http://localhost:8080/metrics
# db_pool_capacity 10
# db_pool_in_use 1
# db_pool_available 9
# db_pool_waiting 0
# db_pool_wait_ratio 0.000
```

The pool size can be tuned via `CHESSMATE_DB_POOL_SIZE` (default 10).

## Resetting the Stack
Need a clean slate? Stop the containers (`docker compose down`), wipe the volumes (`rm -rf data/postgres data/qdrant`), bring services back up, rerun migrations, then re-ingest your PGNs as shown above.

## Documentation
- **Roadmaps & Overviews**
  - [Architecture](docs/handbook/ARCHITECTURE.md) – component diagrams, data flow, and responsibilities.
  - [Review & Planning Notes](docs/handbook/REVIEW_v4.md) – open issues, prioritised work, and follow-up tasks.
- **How-To Guides**
  - [Developer Handbook](docs/handbook/DEVELOPER.md) – environment setup, CLI usage, and daily workflows.
  - [Chessmate for Dummies](docs/handbook/CHESSMATE_FOR_DUMMIES.md) – narrative walkthrough of ingestion and search.
  - [Cookbook](docs/handbook/COOKBOOK.md) – common command sequences and automation snippets.
- **Operations & Testing**
  - [Operations Playbook](docs/handbook/OPERATIONS.md) – deployment, monitoring, and maintenance procedures.
  - [Testing Guide](docs/handbook/TESTING.md) – test matrix, fixtures, and troubleshooting tips.
  - [Load Testing](docs/handbook/LOAD_TESTING.md) – benchmarking harness and performance checklists.
- **Reference & Collaboration**
  - [Troubleshooting](docs/handbook/TROUBLESHOOTING.md) – common failure modes and recovery steps.
  - [Prompts](docs/handbook/PROMPTS.md) – prompt engineering notes and examples for agent tasks.
  - [Collaboration Guidelines](docs/handbook/GUIDELINES.md) – coding standards, PR checklist, and review policy.
- **Generated Guides**
  - `docs/*.mld` – odoc pages (e.g., CLI, pipeline, embedding) rendered via `opam exec -- dune build @doc` and served from `_build/default/_doc/_html/`.

## Contributing
PRs welcome! See [Collaboration Guidelines](docs/handbook/GUIDELINES.md) for coding standards, testing expectations, and PR checklist. Please open an issue before large changes and include `dune build && dune test` output in your PR template.

## License
Distributed under the [GNU General Public License v3.0](LICENSE).
