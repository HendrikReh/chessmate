# Implementation Plan

## Objectives & Scope
- Build a self-hosted chess tutor ("chessmate") capable of answering natural-language questions by correlating structured game metadata with position similarity.
- Use PostgreSQL for canonical PGN storage and metadata, Qdrant for position embeddings, and OpenAI for embedding generation.
- Provide OCaml tooling: CLI for ingestion and retrieval, shared library components, and HTTP services that orchestrate hybrid search.

## High-Level Architecture
- **Relational tier (PostgreSQL)**: stores games, players, positions, annotations, and vector IDs; exposes views for analytics and materialized opening statistics.
- **Vector tier (Qdrant)**: hosts FEN embeddings plus optional sparse representations; payload mirrors key metadata for filtered hybrid search.
- **Embedding worker**: OCaml service batching FEN snapshots, calling OpenAI embeddings, inserting vectors into Qdrant, and recording vector IDs in PostgreSQL.
- **Query/QA service**: HTTP API (Opium/Dream) performing NL parsing, hybrid query planning, Qdrant + Postgres reconciliation, and answer composition.
- **CLIs**: `chessmate ingest` for PGN processing and `chessmate query` for user questions, both calling internal services via HTTP.

## Data Model Plan
- `games`: PGN text, ECO, event/site/date, players, ratings, outcome, tags JSONB, timestamps.
- `players`: name, aliases, FIDE data, rating history snapshots.
- `positions`: game reference, ply number, FEN text/hash, SAN, evaluation score, vector ID (UUID), feature flags.
- `annotations`: optional human/engine commentary attached to positions or games.
- Indices: B-tree for rating/ply filters, GIN/pg_trgm for text, unique `(game_id, ply)` constraint; mirrored payload keys in Qdrant for filtering.

## Library Structure (`lib/`)
- `core/`: pure chess logic and domain types (`Pgn_parser`, `Fen`, `Game_metadata`, `Position_features`).
- `storage/`: persistence layers (`Repo_postgres`, `Repo_qdrant`, `Ingestion_queue`).
- `embedding/`: OpenAI client, caching, and payload builders (`Embedding_client`, `Embeddings_cache`, `Vector_payload`).
- `query/`: NL intent mapping, hybrid planner, result formatting (`Query_intent`, `Hybrid_planner`, `Result_formatter`).
- `cli/`: shared utilities for CLI commands (`Cli_common`, `Ingest_command`, `Search_command`).
- Each `.ml` opens `Base` via `open! Base`; `.mli` files expose minimal public signatures.

## Services & Workflows
1. **Ingestion flow**
   - Parse PGN → normalize metadata and positions → store in Postgres.
   - Enqueue embedding jobs with FEN + metadata snapshot.
   - Worker fetches jobs, calls OpenAI embeddings, upserts to Qdrant, writes vector IDs back.
   - Supports re-embedding with job priorities and throttling.
2. **Query flow**
   - CLI/API receives NL query → intent mapper extracts structured constraints.
   - Planner builds hybrid request (dense + sparse, filter clauses) → queries Qdrant.
   - Reconcile with Postgres to fetch full PGN context, ensure rating/opening filters.
   - Compose natural-language answer with evidence list; optionally call LLM for phrasing.

## Testing Strategy
- Unit tests for core modules and planners using Alcotest with mirrors under `test/`.
- Integration tests using dockerized Postgres/Qdrant fixtures run via `dune test`.
- Regression suites with known chess queries to validate answer stability after changes.

## Deployment & Operations
- Docker Compose stack: Postgres, Qdrant, `chessmate-api`, `embedding-worker`, optional Redis/Postgres job queue. Mount persistent volumes to `./data/postgres` and `./data/qdrant` so database files reside in the repository tree rather than the container filesystem.
- Secure Qdrant behind reverse proxy (mTLS/token); manage OpenAI secrets via environment config.
- Backups: Postgres dumps + WAL archiving; Qdrant snapshots stored encrypted.
- Observability: structured logs (JSON), Prometheus metrics for OCaml services, health endpoints.

### Directory Layout (initial scaffold)
```
.
├── bin/
├── docs/
├── lib/
│   ├── core/
│   ├── storage/
│   ├── embedding/
│   ├── query/
│   └── cli/
├── test/
├── data/
│   ├── postgres/
│   └── qdrant/
├── docker-compose.yml
└── scripts/
```

### docker-compose.yml Sketch
```yaml
version: "3.9"
services:
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: chessmate
      POSTGRES_PASSWORD: change-me
      POSTGRES_DB: chessmate
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  qdrant:
    image: qdrant/qdrant:latest
    restart: unless-stopped
    volumes:
      - ./data/qdrant:/qdrant/storage
    ports:
      - "6333:6333"
      - "6334:6334"

  chessmate-api:
    build: ./services/api
    depends_on:
      - postgres
      - qdrant
    environment:
      DATABASE_URL: postgres://chessmate:change-me@postgres:5432/chessmate
      QDRANT_URL: http://qdrant:6333
    ports:
      - "8080:8080"

  embedding-worker:
    build: ./services/embedding_worker
    depends_on:
      - postgres
      - qdrant
    environment:
      DATABASE_URL: postgres://chessmate:change-me@postgres:5432/chessmate
      QDRANT_URL: http://qdrant:6333
      OPENAI_API_KEY: ${OPENAI_API_KEY}

  redis:
    image: redis:7
    restart: unless-stopped
    volumes:
      - ./data/redis:/data
```

## Milestones & Checkpoints

### Milestone 1 – Repository Scaffolding
**Objective:** Establish project skeleton, build system, and initial tests.
- Tasks:
  - Create `lib/` subdirectories with `dune` files; ensure each module compiles (`open! Base`).
  - Add `test/` suites with Alcotest smoke tests (e.g., verify `Pgn_parser` placeholder).
  - Configure `bin/` CLI entry points (no functionality yet) and ensure `dune build` passes.
- Checkpoints:
  - `dune build` and `dune fmt --check` succeed CI locally.
  - `dune test` runs at least one Alcotest suite.
  - Repository tree matches documented layout (including `data/` dirs).

### Milestone 2 – Data Ingestion Foundations
**Objective:** Parse PGNs, persist metadata, and expose schema migrations.
- Tasks:
  - Implement `Pgn_parser` to extract headers, SAN moves, and generate FEN snapshots.
  - Create SQL migrations (e.g., via `sql/` or embedded migrations) for `games`, `players`, `positions`, `annotations` tables.
  - Develop `Repo_postgres` with CRUD operations; seed sample PGNs for integration tests.
  - Build CLI subcommand `chessmate ingest` that parses a PGN and populates Postgres.
- Checkpoints:
  - Running `dune exec chessmate ingest sample.pgn` loads data and reports success.
  - Postgres tables populated; `SELECT count(*) FROM positions` shows expected rows.
  - Alcotest integration test verifies round-trip (PGN → DB → reconstructed PGN segment).

### Milestone 3 – Embedding Pipeline
**Objective:** Generate embeddings and synchronize Qdrant with Postgres.
- Tasks:
  - Implement `Embedding_client` to call OpenAI with retries/throttling.
  - Add `Vector_payload` builder mapping FEN + metadata to Qdrant payload schema.
  - Create `embedding-worker` service (OCaml) consuming jobs from queue table/Redis.
  - Expose CLI command to enqueue FEN snapshots (`chessmate ingest --enqueue-only`).
- Checkpoints:
  - Local docker-compose brings up Postgres + Qdrant; worker inserts vectors successfully.
  - Postgres rows receive valid `vector_id` references after worker completes.
  - `curl` to Qdrant shows inserted points with payload filters (e.g., `player_white`).

### Milestone 4 – Hybrid Query Service
**Objective:** Answer natural-language questions by combining vector and relational filters.
- Tasks:
  - Implement `Query_intent` module translating NL queries into structured filters (rule-based prototype).
  - Build `Hybrid_planner` to craft Qdrant Query API requests with RRF weights.
  - Develop HTTP API (`chessmate-api`) with endpoints `/query` and `/games/:id`.
  - Implement CLI `chessmate query` hitting the API and displaying ranked results.
- Checkpoints:
  - `dune exec chessmate query "find me five games..."` returns a ranked response referencing both vector similarity and metadata filters.
  - Unit tests cover intent parsing edge cases (opening names, rating constraints).
  - Integration test validates combined Qdrant + Postgres filtering within docker-compose.

### Milestone 5 – Evaluation & Observability
**Objective:** Validate answer quality and production readiness.
- Tasks:
  - Build evaluation harness with curated NL questions and expected evidence sets.
  - Instrument services with metrics (request latency, embed throughput) and health probes.
  - Document runbooks for backups, re-embedding, and scaling.
  - Add CI workflows for lint/test, integration tests against docker-compose, and deployment packaging.
- Checkpoints:
  - Evaluation harness produces pass/fail report; baseline accuracy threshold defined.
  - Prometheus metrics exposed at `/metrics`; dashboards/alerts configured.
  - CI pipeline green on main branch; release artifact or container published.

## Progress Log
- Milestone 1 (Repository Scaffolding): baseline directory structure, stub modules with interfaces, and Alcotest smoke test added. `dune build` / `dune test` succeeding locally.
- Milestone 2 (Ingestion Foundations): added PostgreSQL migration/seed scripts (`scripts/migrate.sh`, `scripts/migrations/`), replaced PGN parser with real header/move extraction, and wired `chessmate ingest` to parse PGNs.
- Milestone 3 (Embedding Pipeline): header parsing maps onto structured `Game_metadata.t`; `chessmate ingest` prepares DB payloads pending driver integration; scaffolded `embedding_worker` executable with polling loop and job lifecycle hooks.
