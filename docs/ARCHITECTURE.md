# Architecture Overview

## System Goals
- Answer natural-language chess questions by combining structured metadata with vector similarity.
- Self-host PostgreSQL + Qdrant; rely on OpenAI only for embedding generation.
- Offer OCaml CLIs and HTTP services to support ingestion and retrieval workflows.

## Component Diagram (logical)
- **Client CLI (`chessmate query`)** → HTTP → **Query API (Opium/Dream)** →
  - Qdrant hybrid search (vector + keyword)
  - PostgreSQL metadata lookups
- **Ingestion pipeline** (`lib/chess/pgn_parser`, `lib/storage/repo_postgres`) →
  - PostgreSQL (games, players, positions)
  - Job queue → Embedding Worker → OpenAI embeddings → Qdrant upsert → Postgres `vector_id` sync

## Data Flow
1. PGN file parsed into headers, SAN moves, per-ply FEN snapshots.
2. Metadata persisted in Postgres; each FEN enqueued for embedding.
3. Worker batches FEN strings, requests OpenAI embeddings, writes to Qdrant with payload (player names, ECO, move number, derived themes).
4. Query API receives NL question, maps to filters/weights, issues Qdrant Query API request with reciprocal rank fusion, cross-checks Postgres for additional constraints, and returns enriched answer.

## Storage Design
- **Postgres**: `games`, `players`, `positions`, `annotations`, `embedding_jobs`. Uses JSONB tags, trigram indexes, and materialized views for statistics.
- **Qdrant**: Collection `positions` with dense vector (FEN embedding), optional sparse vector (SAN/comment tokens), payload for metadata filters; uses RRF to combine vector + lexical scores.
- **Data volumes**: persisted under `data/postgres`, `data/qdrant` to survive container restarts.

## Module Boundaries (OCaml)
- `lib/chess`: PGN/FEN parsing, metadata models, derived features.
- `lib/storage`: database + queue facades (Postgres, embedding job queues, future Qdrant adapter).
- `lib/embedding`: OpenAI client, caching, payload builders.
- `lib/query`: intent analysis, hybrid planner, result formatting (milestone 4 scope).
- `lib/cli`: shared CLI glue for ingestion and query commands (currently being wired).

## Service Responsibilities
- **Query API** (planned): parse questions, orchestrate hybrid search, format answers, expose health/metrics endpoints.
- **Embedding Worker**: resilient embedding pipeline with retry/backoff, batch size tuning, and queue management.
- **Background Jobs** (planned): re-embedding, snapshot validation, analytics refresh.

## External Integrations
- OpenAI embeddings (HTTP) with API key auth.
- Optional LLM for answer phrasing, invoked as a downstream service with guardrails.
- Observability stack (Prometheus + Loki) to capture metrics/logs from all OCaml services.

## Future Enhancements
- Replace rule-based intent parser with fine-tuned LLM classifier; keep deterministic fallback.
- Add caching layer (Redis) for frequently asked questions and feature store for player statistics.
- Support distributed deployment (Kubernetes/Nomad) once workloads exceed single-host Compose setup.
