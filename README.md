# Chessmate

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.1-orange.svg)](https://ocaml.org)
[![Version](https://img.shields.io/badge/Version-0.4.0-blue.svg)](RELEASE_NOTES.md)
[![Status](https://img.shields.io/badge/Status-Proof%20of%20Concept-yellow.svg)](docs/IMPLEMENTATION_PLAN.md)
[![Build Status](https://img.shields.io/github/actions/workflow/status/HendrikReh/chessmate/ci.yml?branch=master)](https://github.com/HendrikReh/chessmate/actions)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](docs/GUIDELINES.md)
[![Collaboration](https://img.shields.io/badge/Collaboration-Guidelines-blue.svg)](docs/GUIDELINES.md)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-active-green.svg)](https://github.com/HendrikReh/chessmate/graphs/commit-activity)

Self-hosted chess tutor that blends relational data (PostgreSQL) with vector search (Qdrant) to answer natural-language questions about annotated chess games. OCaml powers ingestion, hybrid retrieval, and CLI tooling.

## Requirements
- OCaml 5.1.0 (managed via opam) and Dune ≥ 3.20.
- Docker & Docker Compose (local Postgres + Qdrant stack).
- PostgreSQL client (`psql`) on your `PATH`.
- `curl` (embedding worker diagnostics).
- Optional: `OPENAI_API_KEY` if you want to run the embedding worker against OpenAI.

## Feature Highlights
- **PGN ingestion pipeline:** parses headers/SAN, derives per-ply FEN snapshots, extracts ECO codes, and persists metadata (players, openings, results) to Postgres.
- **Opening catalogue:** maps natural-language opening phrases to ECO ranges (`lib/chess/openings`), so queries like “King’s Indian games” become deterministic filters.
- **Prototype hybrid search:** milestone 4 ships an Opium-based `/query` API (`dune exec chessmate_api`) plus `chessmate query` CLI surfacing intent analysis and curated sample results.
- **Embedding worker skeleton:** polls `embedding_jobs`, calls OpenAI embeddings, and records vector identifiers ready for Qdrant sync.
- **Diagnostics tooling:** `chessmate fen <game.pgn>` prints per-ply FENs; ingestion/worker CLIs emit structured logs for troubleshooting.

## Getting Started
1. Clone and enter the repository.
2. Create an opam switch and install dependencies:
   ```sh
   opam switch create . 5.1.0
   opam install . --deps-only --with-test
   ```
3. Launch backing services (Postgres, Qdrant) via Docker (first run may take a minute while images download):
   ```sh
   docker compose up -d postgres qdrant
   ```
4. Initialize the database (migrations expect `DATABASE_URL` to be set):
   ```sh
   # Example connection string; adjust credentials/port if you changed docker-compose.yml
   export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
   ./scripts/migrate.sh
   ```
5. Build & test the workspace:
   ```sh
   dune build
   dune runtest
   ```
6. Explore the available tooling:
   ```sh
   # Start the prototype query API (Opium server)
   dune exec -- chessmate-api --port 8080
   
   # In another shell, call the API via the CLI (set CHESSMATE_API_URL if you changed the port)
   CHESSMATE_API_URL=http://localhost:8080 dune exec chessmate -- query "Find King's Indian games where White is 2500 and Black 100 points lower"

   # Ingest a PGN (persists players/games/positions/openings)
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec chessmate -- ingest test/fixtures/extended_sample_game.pgn

   # Run the embedding worker loop (requires OPENAI_API_KEY for real embeddings)
   OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec embedding_worker

   # Generate FENs from a PGN for quick inspection
   chessmate fen test/fixtures/sample_game.pgn
   ```

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

## Services & CLIs
- `dune exec chessmate_api -- --port 8080`: starts the prototype query HTTP API.
- `chessmate ingest <pgn>`: parses and persists PGNs (requires `DATABASE_URL`).
- `chessmate twic-precheck <pgn>`: scans TWIC PGNs for malformed entries before ingestion.
- `chessmate query "…"`: sends questions to the running query API (`CHESSMATE_API_URL` defaults to `http://localhost:8080`).
- `chessmate fen <pgn> [output]`: prints FEN after each half-move (optional output file).
- `OPENAI_API_KEY=… chessmate embedding-worker`: polls `embedding_jobs`, calls OpenAI, updates vector IDs.

### CLI Usage
Example CLI session (assuming Postgres is running locally):
```sh
export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate
CHESSMATE_API_URL=http://localhost:8080

# Ingest a PGN
chessmate ingest test/fixtures/extended_sample_game.pgn
# => Stored game 1 with 77 positions

# Ask a question (make sure the API is running in another shell)
chessmate query "Show French Defense draws with queenside majority endings"
# => Summary, filters, and curated results printed to stdout

# Generate FENs (stdout, filtered, file output)
chessmate fen test/fixtures/sample_game.pgn
chessmate fen test/fixtures/sample_game.pgn | head -n 5
chessmate fen test/fixtures/sample_game.pgn /tmp/fens.txt

# Show plan as JSON
chessmate query --json "Find King's Indian games" | jq '.'

# Batch ingest PGNs (simple shell loop)
for pgn in fixtures/*.pgn; do
  chessmate ingest "$pgn"
done
```

Worker loop with log snippets (using a dummy API key in dry-run mode):
```sh
OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  chessmate embedding-worker
# [worker] starting polling loop
# [worker] job 42 completed
```

FEN tooling for sanity checks:
```sh
chessmate fen test/fixtures/sample_game.pgn | head -n 5
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

## Repository Structure
```
lib/            # OCaml libraries (chess, storage, embedding, query, cli)
bin/            # CLI entry points
scripts/        # Database migrations (`migrate.sh`, `migrations/`, seeds)
services/       # Long-running services (e.g., embedding_worker, API prototype)
docs/           # Architecture, developer, ops, and planning docs
test/           # Alcotest suites
data/           # Bind-mounted volumes for Postgres and Qdrant
```

## Resetting the Stack
Need a clean slate? Stop the containers (`docker compose down`), wipe the volumes (`rm -rf data/postgres data/qdrant`), bring services back up, rerun migrations, then re-ingest your PGNs as shown above.

## Documentation
- [Implementation Plan](docs/IMPLEMENTATION_PLAN.md)
- [Architecture Overview](docs/ARCHITECTURE.md)
- [Developer Handbook](docs/DEVELOPER.md)
- [Operations Playbook](docs/OPERATIONS.md)
- [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
- [Collaboration Guidelines](docs/GUIDELINES.md)

## Contributing
PRs welcome! See [Collaboration Guidelines](docs/GUIDELINES.md) for coding standards, testing expectations, and PR checklist. Please open an issue before large changes and include `dune build && dune test` output in your PR template.

## License
Distributed under the [GNU General Public License v3.0](LICENSE).
