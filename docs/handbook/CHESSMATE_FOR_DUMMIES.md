# Chessmate for Dummies – 2025 Edition

This guide walks through Chessmate from scratch—how games are ingested, how metadata and vectors are stored, and how hybrid retrieval answers chess questions. It’s meant for newcomers who want a narrative overview.

> Fastlinks: [Architecture](ARCHITECTURE.md) · [Developer Handbook](DEVELOPER.md) · [Operations Playbook](OPERATIONS.md) · [Testing Plan](TESTING.md)

---

## 0. Quick Sanity Run

Before diving in, verify the end-to-end path still works:

```sh
export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres
eval "$(opam env --set-switch)"
dune exec test/test_main.exe -- test integration
```

This ingests a fixture PGN, drains the embedding queue (with stubs), and runs a hybrid query against a throwaway database. If it passes, you’re good.

---

## 1. Chessmate in One Paragraph

Chessmate ingests PGN games, stores metadata and FEN snapshots in PostgreSQL, embeds positions into Qdrant, and answers natural-language questions by blending deterministic filters (openings/ratings/keywords) with vector similarity. Optionally, GPT‑5 re-ranks results and explains themes, with Redis caching to keep costs down. Everything runs on your infrastructure; OpenAI is only used for embeddings and (if enabled) agent scoring.

---

## 2. From PGN to Postgres & Qdrant

1. **PGN ingestion (CLI)** – `chessmate ingest game.pgn`
   - Parses headers, SAN moves, and derives per-move FEN snapshots (`lib/chess/pgn_parser`, `lib/chess/pgn_to_fen`).
2. **Metadata persistence** – `Repo_postgres` inserts players, games, and positions. Each position gets an `embedding_job` entry. `CHESSMATE_MAX_PENDING_EMBEDDINGS` enforces a queue guard.
3. **Embedding worker** – Polls `embedding_jobs`, batches FENs, calls OpenAI embeddings (`lib/embedding/embedding_client`), upserts vectors into Qdrant (`Repo_qdrant`), and marks jobs complete/failed. Startup now ensures the collection exists (configurable via `QDRANT_COLLECTION_NAME`, `QDRANT_VECTOR_SIZE`, `QDRANT_DISTANCE`).
4. **Retry & telemetry** – Worker retries transient errors with exponential backoff, emits structured logs, and tracks processed/failed jobs.

**Data snapshot**
- Postgres: `games`, `players`, `positions (fen/san/vector_id)`, `embedding_jobs`.
- Qdrant: `positions` collection storing embeddings plus payload (players, ECO, themes).
- Redis (optional): agent evaluation cache keyed by plan + game id.

---

## 3. Answering a Question

1. **CLI/API entry** – `chessmate query [--json] "How did Kasparov attack the king?"`
   - Runs dependency health probes (Postgres, Qdrant, Redis), then enforces per-IP rate limiting (`lib/api/rate_limiter`). 429 responses include `Retry-After`.
2. **Intent analysis** – `Query_intent.analyse` normalises text, extracts keywords/opening/rating filters, applies result limits.
3. **Hybrid planning** – `Hybrid_planner` builds SQL predicates and optional Qdrant payload filters. `Hybrid_executor` fetches candidates from Postgres and parallel vector hits from Qdrant.
4. **Agent scoring** – Redis cache checked first. On miss, GPT-5 is invoked (configurable effort/verbosity). Future iteration adds request timeouts, circuit breakers, and fallback warnings.
5. **Response formatting** – `Result_formatter` merges heuristic/agent scores, themes, explanations, and produces JSON plus CLI summary.

**CLI Health Bill**
```
[health] postgres      ok (pending_jobs=0)
[health] qdrant        ok (200 /healthz)
[health] redis         skipped (AGENT_CACHE_REDIS_URL not set)
[health] chessmate-api ok
```

---

## 4. Reliability & Observability Cheat Sheet

| Feature | Status | Notes |
| --- | --- | --- |
| Rate limiting | ✅ | Token-bucket per IP via `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` (+ body budget `CHESSMATE_RATE_LIMIT_BODY_BYTES_PER_MINUTE`). Metrics: `api_rate_limited_total`, `api_rate_limited_body_total`. |
| Qdrant bootstrap | ✅ | `Repo_qdrant.ensure_collection` runs at API/worker startup. |
| Health probes | 🔄 | CLI covers Postgres/Qdrant/Redis; `/health` JSON + worker endpoint planned. |
| GPT-5 timeout/breaker | 🔄 | Upcoming: per-request timeout, fallback warnings, circuit breaker, metrics. |
| Metrics | ☑️ | Caqti pool gauges, rate limiter counters; latency/error histograms to follow. |
| Telemetry | ✅ | GPT-5 agent logs latency/tokens/cost; CLI/formatting uses ocamlformat `0.27.0`. |

Legend: ✅ shipped · ☑️ partial · 🔄 planned.

---

## 5. Configuration & Env Vars

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Postgres DSN (required). |
| `QDRANT_URL` | Qdrant base URL (required). |
| `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` | Per-IP quota; optional `CHESSMATE_RATE_LIMIT_BUCKET_SIZE` for bursts. |
| `CHESSMATE_RATE_LIMIT_BODY_BYTES_PER_MINUTE` | Optional per-IP body-size quota (`CHESSMATE_RATE_LIMIT_BODY_BUCKET_SIZE` for bursts). |
| `CHESSMATE_MAX_REQUEST_BODY_BYTES` | Per-request body limit (default 1 MiB; set `0` to disable). |
| `QDRANT_COLLECTION_NAME`, `QDRANT_VECTOR_SIZE`, `QDRANT_DISTANCE` | Collection bootstrap settings (defaults: `positions`, `1536`, `Cosine`). |
| `AGENT_API_KEY` et al. | GPT-5 agent scoring (optional). |
| See [Developer Handbook](DEVELOPER.md#configuration-reference) for the full table. |

Formatting note: run `dune fmt` (ocamlformat `conventional`/`0.27.0`) before committing; CI runs `dune build @fmt`.

---

## 6. Quick Start Commands

```sh
# Bootstrap (optional but recommended)
./bootstrap.sh

# Ingest a PGN
DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  dune exec -- chessmate -- ingest test/fixtures/extended_sample_game.pgn

# Run embedding worker
OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  dune exec -- embedding_worker -- --workers 2 --poll-sleep 1.0

# Start API
dune exec -- services/api/chessmate_api.exe --port 8080

# Ask a question (JSON mode)
CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query --json "Show French Defense draws"
```

---

## 7. Want to Dive Deeper?
- Architecture diagrams and module breakdown: [ARCHITECTURE.md](ARCHITECTURE.md)
- Detailed operations guidance: [OPERATIONS.md](OPERATIONS.md)
- Prompt engineering ideas for GPT-5 scoring: [PROMPTS.md](PROMPTS.md)
- Outstanding work and future plans: [REVIEW_v5.md](REVIEW_v5.md)

Happy hacking! Chessmate blends classic chess knowledge with modern retrieval—keep the guardrails strong and the vectors fresh.
