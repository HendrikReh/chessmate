# Architecture Overview

## System Goals
- Answer natural-language chess questions by combining structured metadata with vector similarity.
- Self-host PostgreSQL + Qdrant; rely on OpenAI only for embedding generation.
- Offer OCaml CLIs and HTTP services to support ingestion and retrieval workflows.

## Visual Overview
```mermaid
flowchart TD
  subgraph Clients
    CLI["CLI (chessmate)"]
  end

  subgraph Services
    API["Query API (Opium)"]
    Worker["Embedding Worker"]
  end

  subgraph Storage
    PG[("PostgreSQL")]
    QD[("Qdrant")]
  end

  subgraph Integrations
    OpenAI[("OpenAI Embeddings")]
  end

  CLI -->|"HTTP /query"| API
  CLI -->|"Ingest PGN"| PG
  API -->|"Metadata lookups"| PG
  API -->|"Vector search"| QD
  Worker -->|"Embedding jobs"| PG
  Worker -->|"Vectors"| QD
  Worker -->|"Embed FENs"| OpenAI
  PG -->|"Opening metadata"| CLI
```

## Component Overview
- **CLI & API Layer**: `chessmate ingest` / `chessmate query` commands and the Opium-based `/query` service route user intent into the platform.
- **Ingestion pipeline** (`lib/chess/pgn_parser`, `lib/storage/repo_postgres`): parses PGNs, derives FEN snapshots, extracts ECO/opening metadata, persists games/positions/embedding jobs in Postgres, and now enforces a configurable guard to pause ingestion when the embedding queue is saturated.
- **Embedding pipeline** (`services/embedding_worker`): polls `embedding_jobs`, batches FEN strings, calls OpenAI embeddings, writes vectors to Qdrant, and records `vector_id` back in Postgres. Operators track throughput with `scripts/embedding_metrics.sh` while scaling workers via the `--workers` flag and rely on `CHESSMATE_MAX_PENDING_EMBEDDINGS` to keep ingest pressure in check.
- **Hybrid query pipeline** (`lib/query`, `lib/chess/openings`): converts natural-language questions into structured filters (openings/ratings/phases), plans hybrid metadata/vector lookups, and assembles responses.

## Data Flow
```mermaid
graph LR
  A[PGN File] -->|Parse headers/SAN/FEN| B[Ingestion Pipeline]
  B -->|Persist players/games/positions| C[(PostgreSQL)]
  B -->|Enqueue FEN jobs| D[embedding_jobs]
  E[Embedding Worker] -->|Poll jobs| D
  E -->|Call embeddings| F[(OpenAI API)]
  E -->|Upsert vectors| G[(Qdrant)]
  E -->|Update vector_id| C
  H[Query CLI/API] -->|Natural language question| I[Query Intent]
  I -->|Opening/rating filters| J[Planner]
  J -->|Metadata lookup| C
  J -->|Vector lookup| G
  J -->|Formatted response| H
```

Detailed steps:
1. **Ingest**: PGN file → parse headers/SAN/FEN → extract player, result, ECO/opening slug → persist to Postgres (`games`, `players`, `positions`) → enqueue `embedding_jobs` for each FEN, with a guard on queue depth (`CHESSMATE_MAX_PENDING_EMBEDDINGS`) to keep backlog manageable.
2. **Embed**: Worker polls pending jobs → batches FENs → calls OpenAI embeddings → upserts into Qdrant (vector + payload) → updates Postgres `positions.vector_id` and job status.
3. **Query**: CLI/API receives question → `Query_intent.analyse` normalizes text, maps openings via ECO catalogue, infers rating/phase filters → prototype planner scores curated vector/keyword results (future: live Postgres + Qdrant queries) → aggregates response via `Result_formatter`.

## Storage Design
- **PostgreSQL**: `games` (players, ECO, opening_slug), `positions` (ply, fen, san, vector_id), `embedding_jobs`, `annotations`. Additional indexes on ratings, ECO, opening slug, and vector_id accelerate filtering.
- **Qdrant**: `positions` collection holding dense FEN embeddings and payload fields (player names, ECO range, move metadata) to support hybrid queries.
- **Volumes**: `data/postgres` and `data/qdrant` mount persistent storage under Docker Compose for reproducible local environments.

## Module Boundaries
- `lib/chess`: PGN/FEN parsing, ECO/opening catalogue, domain metadata models.
- `lib/storage`: Postgres primitives (`Repo_postgres`), embedding queue helpers, future Qdrant adapter.
- `lib/embedding`: OpenAI client stubs, payload builders, caching (planned).
- `lib/query`: intent parsing, hybrid planner scaffold, result formatting.
- `lib/cli`: shared CLI glue + ingest/query subcommands.
- `services/`: standalone executables (embedding worker, API prototype).

## Service Responsibilities
- **Query API (prototype)**: Opium HTTP service (`/query`) that parses intent, applies opening/rating filters, and returns curated responses. When `AGENT_API_KEY` is present it also invokes GPT-5 to re-rank results, add explanations/themes, and reports token usage. Future work: wire to live Postgres/Qdrant, expose metrics/health endpoints.
- **Embedding Worker**: long-running job consumer with retry/backoff, batching, and state transitions.
- **Background Jobs** (planned): re-embedding runs, data validation, analytics refresh pipelines.

## Sequence Diagrams
### Ingestion + Embedding
```mermaid
sequenceDiagram
  participant CLI as chessmate ingest
  participant Parser as PGN Parser
  participant PG as PostgreSQL
  participant Jobs as embedding_jobs
  participant Worker as Embedding Worker
  participant OpenAI as OpenAI API
  participant QD as Qdrant

  CLI->>Parser: parse PGN (headers, SAN, FEN)
  Parser-->>CLI: metadata + moves
  CLI->>PG: INSERT game/player/positions
  CLI->>Jobs: INSERT embedding job rows
  Worker->>Jobs: fetch pending jobs
  Worker->>PG: mark job started
  Worker->>OpenAI: embed FEN batch
  OpenAI-->>Worker: vectors
  Worker->>QD: upsert vectors + payload
  Worker->>PG: mark job completed (vector_id)
```

### Query Prototype
```mermaid
sequenceDiagram
  participant User as User/CLI
  participant API as Query API
  participant Intent as Query Intent
  participant Planner as Hybrid Planner
  participant Catalog as Openings Catalogue
  participant Store as PostgreSQL/Qdrant (planned)

  User->>API: GET/POST /query
  API->>Intent: analyse(question)
  Intent->>Catalog: map openings to ECO ranges
  Catalog-->>Intent: opening slug + range
  Intent-->>Planner: plan (filters, keywords, rating)
  Planner->>Store: (future) fetch metadata + vectors
  Planner-->>API: curated results (prototype dataset)
  API-->>User: JSON response (plan + results)
```

### Embedding Job State Transitions
```mermaid
stateDiagram-v2
  [*] --> Pending
  Pending --> InProgress: worker polls job
  InProgress --> Completed: vector stored + job updated
  InProgress --> Failed: OpenAI/Qdrant error
  Failed --> Pending: retry/backoff strategy
  Completed --> [*]
```

### Module Relationships
```mermaid
classDiagram
  class Chess {
    +Pgn_parser
    +Game_metadata
    +Openings
    +Pgn_to_fen
  }
  class Storage {
    +Repo_postgres
    +Ingestion_queue
  }
  class Embedding {
    +Embedding_client
    +Embeddings_cache
    +Vector_payload
  }
  class Query {
    +Query_intent
    +Hybrid_planner
    +Result_formatter
  }
  class CLI {
    +Ingest_command
    +Search_command
    +Cli_common
  }
  class Services {
    +Embedding_worker
    +Chessmate_api
  }
  Chess --> Storage : persist games/positions
  Chess --> Query : opening catalogue
  Storage --> Embedding : enqueue jobs
  Embedding --> Storage : update vector_id
  Query --> Storage : metadata lookups (planned)
  Query --> Embedding : vector scoring (planned)
  CLI --> Storage : ingest (DATABASE_URL)
  CLI --> Services : query via HTTP API
  Services --> Query : leverage planner modules
```

### Failure Path Example (Embedding Error)
```mermaid
sequenceDiagram
  participant Worker as Embedding Worker
  participant Jobs as embedding_jobs
  participant PG as PostgreSQL
  participant OpenAI as OpenAI API

  Worker->>Jobs: fetch pending job
  Worker->>PG: mark job started
  Worker->>OpenAI: embed FEN batch
  OpenAI-->>Worker: error response / rate limit
  Worker->>PG: mark job failed (last_error)
  Worker-->>Jobs: schedule retry after backoff
```

## External Integrations
- OpenAI embeddings API (ingestion/worker).
- Future: Qdrant live queries (HTTP/gRPC) in the planner.
- Observability (planned): structured logging + Prometheus metrics for worker/API.

## Future Enhancements
- Replace heuristic planner with live Postgres/Qdrant hybrid search (RRF, payload filters).
- Intent upgrades: expand opening catalogue, consider LLM-assisted classification with deterministic fallbacks.
- Add Redis (or similar) caching for frequently asked questions / evaluation fixtures.
- Deployment hardening: containerize API/worker, add CI integration tests, explore Kubernetes/Nomad rollouts.
