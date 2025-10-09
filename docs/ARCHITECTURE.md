# Architecture Overview

## System Goals

### Related Documentation
- [Implementation Plan](IMPLEMENTATION_PLAN.md) – milestone roadmap and future phases.
- [Operations Playbook](OPERATIONS.md) – day-to-day service management and runtime procedures.
- [Chessmate for Dummies](CHESSMATE_FOR_DUMMIES.md) – narrative walkthrough of the same pipelines for non-engineers.
- [Developer Handbook](DEVELOPER.md) – onboarding, tooling, and local environment setup.

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
    Agent["Agent Evaluator"]
    Worker["Embedding Worker"]
  end

  subgraph Storage
    PG[("PostgreSQL")]
    QD[("Qdrant")]
    Redis[("Redis Agent Cache")]
  end

  subgraph Integrations
    OpenAIEmb[("OpenAI Embeddings")]
    OpenAIGPT[("OpenAI GPT-5 Responses")]
  end

  CLI -->|"HTTP /query"| API
  CLI -->|"Ingest PGN"| PG
  API -->|"Metadata + PGNs"| PG
  API -->|"Vector search"| QD
  API -->|"Cache lookups"| Redis
  API -->|"Agent scoring"| Agent
  Agent -->|"Cache hits"| Redis
  Agent -->|"GPT-5 evaluations"| OpenAIGPT
  Agent -->|"Scores & explanations"| API
  Worker -->|"Embedding jobs"| PG
  Worker -->|"Vectors"| QD
  Worker -->|"Embed FENs"| OpenAIEmb
  PG -->|"Opening metadata"| CLI
```

## Component Overview
- **CLI & API Layer**: `chessmate ingest` / `chessmate query` commands and the Opium-based `/query` service route user intent into the platform.
- **Ingestion pipeline** (`lib/chess/pgn_parser`, `lib/storage/repo_postgres`): parses PGNs, derives FEN snapshots, extracts ECO/opening metadata, persists games/positions/embedding jobs in Postgres, and now enforces a configurable guard to pause ingestion when the embedding queue is saturated.
- **Embedding pipeline** (`services/embedding_worker`): polls `embedding_jobs`, batches FEN strings, calls OpenAI embeddings, writes vectors to Qdrant, and records `vector_id` back in Postgres. Operators track throughput with `scripts/embedding_metrics.sh` while scaling workers via the `--workers` flag and rely on `CHESSMATE_MAX_PENDING_EMBEDDINGS` to keep ingest pressure in check.
- **Hybrid query pipeline** (`lib/query`, `lib/chess/openings`): turns natural-language questions into openings/ratings/keyword filters, queries Postgres (and Qdrant when configured), fetches PGNs, evaluates candidates via the GPT-5 agent with Redis caching (`Agent_evaluator`, `Agent_cache`, `Agents_gpt5_client`, `Agent_telemetry`), and assembles ranked responses.

## Data Flow
```mermaid
graph LR
  A[PGN File] -->|Parse headers/SAN/FEN| B[Ingestion Pipeline]
  B -->|Persist players/games/positions| C[(PostgreSQL)]
  B -->|Enqueue FEN jobs| D[embedding_jobs]
  E[Embedding Worker] -->|Poll jobs| D
  E -->|Call embeddings| F[(OpenAI Embeddings)]
  E -->|Upsert vectors| G[(Qdrant)]
  E -->|Update vector_id| C
  H[Query CLI/API] -->|Natural language question| I[Query Intent]
  I -->|Filters & keywords| J[Hybrid Planner]
  J -->|Candidate metadata| C
  J -->|Vector candidates| G
  J -->|Candidate ids| K[PGN Fetcher]
  K -->|Retrieve PGNs| C
  K -->|PGNs| L[Agent Evaluator]
  L -->|Cache lookup| Redis[(Redis Agent Cache)]
  Redis -->|Cached scores| L
  L -->|Call GPT-5 on miss| OpenAIGPT[(OpenAI GPT-5 Responses)]
  L -->|Scores & explanations| M[Result Aggregator]
  M -->|Structured response| H
```

Detailed steps:
1. **Ingest**: PGN file → parse headers/SAN/FEN → extract player, result, ECO/opening slug → persist to Postgres (`games`, `players`, `positions`) → enqueue `embedding_jobs` for each FEN, with a guard on queue depth (`CHESSMATE_MAX_PENDING_EMBEDDINGS`) to keep backlog manageable.
2. **Embed**: Worker polls pending jobs → batches FENs → calls OpenAI embeddings → upserts into Qdrant (vector + payload) → updates Postgres `positions.vector_id` and job status.
3. **Query**: CLI/API receives question → `Query_intent.analyse` normalizes text, resolves opening synonyms via the ECO catalogue, and infers rating/phase filters → `Hybrid_planner` gathers metadata from Postgres (and Qdrant vectors when enabled) to produce candidate game ids → API fetches PGNs, checks the Redis-backed agent cache, and invokes GPT-5 for fresh evaluations when necessary → agent scores/explanations are merged with heuristic scores and formatted via `Result_formatter`.

## Storage Design
- **PostgreSQL**: `games` (players, ECO, opening_slug), `positions` (ply, fen, san, vector_id), `embedding_jobs`, `annotations`. Additional indexes on ratings, ECO, opening slug, and vector_id accelerate filtering.
- **Qdrant**: `positions` collection holding dense FEN embeddings and payload fields (player names, ECO range, move metadata) to support hybrid queries.
- **Redis**: agent evaluation cache storing GPT-5 scores/explanations keyed by the analysis plan + game id; backed by the `redis` service in Docker Compose.
- **Volumes**: `data/postgres`, `data/qdrant`, and `data/redis` mount persistent storage under Docker Compose for reproducible local environments.

## Module Boundaries
- `lib/chess`: PGN/FEN parsing, ECO/opening catalogue, domain metadata models.
- `lib/storage`: Postgres primitives (`Repo_postgres`), Qdrant adapter (`Repo_qdrant`), embedding queue helpers.
- `lib/embedding`: OpenAI embedding client, vector payload builders, and local embedding cache helpers.
- `lib/query`: intent parsing, hybrid planner, agent evaluator/cache/telemetry, result formatting.
- `lib/agents_gpt5_client`: GPT-5 Responses client with configurable effort/verbosity and retries.
- `lib/cli`: shared CLI glue + ingest/query subcommands.
- `services/`: standalone executables (embedding worker, API prototype).

## Service Responsibilities
- **Query API**: Opium HTTP service (`/query`) that parses intent, applies opening/rating filters, fetches metadata + PGNs from Postgres, optionally queries Qdrant, and re-ranks results via the GPT-5 agent with Redis-backed caching and telemetry. Upcoming work: enable live Qdrant re-ranking and expose richer metrics/health endpoints.
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

### Query Flow with Agent Evaluation
```mermaid
sequenceDiagram
  participant User as User/CLI
  participant API as Query API
  participant Intent as Query Intent
  participant Catalog as Openings Catalogue
  participant Planner as Hybrid Planner
  participant Postgres as Repo_postgres
  participant Qdrant as Repo_qdrant
  participant Cache as Redis Cache
  participant Agent as Agent Evaluator
  participant GPT5 as OpenAI GPT-5

  User->>API: GET/POST /query
  API->>Intent: analyse(question)
  Intent->>Catalog: map openings to ECO ranges
  Catalog-->>Intent: opening slug + range
  Intent-->>Planner: plan (filters, keywords, rating)
  Planner->>Postgres: fetch candidate metadata
  Planner->>Qdrant: fetch vector candidates (when enabled)
  Planner-->>API: candidate ids + heuristics
  API->>Postgres: fetch PGNs for candidates
  API->>Cache: lookup agent evaluations
  alt cache hit
    Cache-->>API: cached scores/explanations
  else cache miss
    API->>Agent: evaluate candidates
    Agent->>GPT5: call Responses API
    GPT5-->>Agent: scores + rationale
    Agent->>Cache: store evaluation
    Agent-->>API: scores/explanations
  end
  API-->>User: JSON response (plan + ranked results)
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
    +Repo_qdrant
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
    +Agent_evaluator
    +Agent_cache
    +Agent_response
    +Agent_telemetry
    +Result_formatter
  }
  class Agents {
    +Agents_gpt5_client
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
  Query --> Storage : metadata & PGNs
  Query --> Embedding : vector scoring (planned)
  Query --> Agents : GPT-5 responses
  CLI --> Storage : ingest (DATABASE_URL)
  CLI --> Services : query via HTTP API
  Services --> Query : leverage planner modules
  Services --> Agents : invoke GPT-5
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

### Failure Path Example (Agent Evaluation Error)
```mermaid
sequenceDiagram
  participant API as Query API
  participant Cache as Redis Cache
  participant Agent as Agent Evaluator
  participant GPT5 as OpenAI GPT-5
  participant Log as Agent Telemetry

  API->>Cache: lookup evaluation key
  alt cache hit
    Cache-->>API: cached scores
  else cache miss
    API->>Agent: evaluate candidates
    Agent->>GPT5: Responses API call
    GPT5-->>Agent: error / rate limit
    Agent->>Log: record failure + tokens
    Agent-->>API: Or_error failure
  end
  note right of API: Fall back to heuristic ranking when agent evaluation fails
```

## External Integrations
- OpenAI embeddings API (ingestion/worker).
- OpenAI GPT-5 Responses API (agent evaluator with controllable reasoning effort).
- Qdrant HTTP/gRPC endpoints (vectors written today; query-side reads land in Milestone 6).
- Observability (planned): structured logging + Prometheus metrics for worker/API.

## Future Enhancements
- Phase 2: replace heuristic planner with live Postgres/Qdrant hybrid search (RRF, payload filters, vector re-ranking).
- Intent upgrades: expand opening catalogue, consider LLM-assisted classification with deterministic fallbacks.
- Agent maturity: richer caching metrics, configurable TTL policies, and dashboards for cost/latency outliers.
- Deployment hardening: containerize API/worker, add CI integration tests, explore Kubernetes/Nomad rollouts.
