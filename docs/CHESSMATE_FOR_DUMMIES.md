# Complete System Overview: From Chess Game to Natural Language Search

This document explains how Chessmate ingests chess games, stores information across PostgreSQL and Qdrant, and processes natural language queries to deliver relevant results.

> Looking for a blueprint or operational details? See the [Architecture Overview](ARCHITECTURE.md) for component diagrams, [Operations Playbook](OPERATIONS.md) for runbooks, and [Developer Handbook](DEVELOPER.md) for setup instructions. Prompt engineering ideas live in [PROMPTS.md](PROMPTS.md).

---

## Lightning Sanity Check

Want proof everything still hangs together? Run the integration suite that accompanies this doc. It ingests a fixture PGN, walks the embedding queue, and exercises the hybrid search pipeline against a temporary database.

```bash
export CHESSMATE_TEST_DATABASE_URL="postgres://chess:chess@localhost:5433/postgres"
eval "$(opam env --set-switch)"
psql "$CHESSMATE_TEST_DATABASE_URL" -c '\conninfo'               # optional: verify credentials
dune exec test/test_main.exe -- list                             # optional: inspect named suites
dune exec test/test_main.exe -- test integration                 # run only the integration cases
```

- The URL must grant `CREATEDB`; the tests create and drop an isolated database per run.
- Postgres must be reachable at that URL—if the connection fails, the suite stops immediately and reports the database error. With the provided Docker Compose stack run `docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"` once to grant the required privilege.
- No Qdrant or OpenAI credentials are required—the suite stubs vector hits so it works offline.
- Expect several seconds of runtime while migrations execute and ingestion completes.

If you skip the test, the rest of this guide still applies; you just miss out on a fast regression check.

---

## What is Semantic Search?

Before diving in, let's understand the concept: Traditional search matches exact keywords (like Google in the 1990s). **Semantic search** understands *meaning*. For example, if you search for "King's Indian games," the system knows you're looking for games with ECO codes E60-E99, even though "E60-E99" never appears in your query.

Chessmate uses **hybrid search**: combining traditional filters (player ratings, opening codes) with **vector embeddings** (numerical representations of chess positions that capture their characteristics).

---

## Part 1: Ingestion - Getting Chess Games Into The System

### Step 1: Parsing PGN Files (`lib/chess/pgn_parser.ml`)

When you run `chessmate ingest game.pgn`, the system:

1. **Reads the PGN file** - a chess game format with headers and moves:
   ```
   [Event "World Championship"]
   [White "Kasparov, Garry"]
   [Black "Karpov, Anatoly"]
   [WhiteElo "2800"]
   [BlackElo "2750"]
   [Result "1-0"]
   [ECO "E97"]

   1. d4 Nf6 2. c4 g6 3. Nc3 Bg7 ...
   ```

2. **Extracts headers** → player names, ratings, event, result, ECO code
3. **Parses moves** → converts algebraic notation (e4, Nf3) into structured data

### Step 2: Generating FEN Snapshots (`lib/chess/pgn_to_fen.ml`)

For *every half-move* (ply), the system generates a **FEN string** - a text representation of the board position:

```
rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1
```

This FEN captures:
- Piece placement
- Who moves next
- Castling rights
- En passant squares
- Move counters

**Why?** Each position becomes searchable independently. You can find "French Defense endgames" by searching positions at ply 40+, not just full games.

### Step 3: Extracting Opening Information (`lib/chess/openings.ml`)

The system maintains a **catalogue** mapping opening names to ECO codes:

```ocaml
King's Indian Defense → E60-E99
French Defense → C00-C19
Sicilian Defense → B20-B99
```

It also handles **synonyms**: "king's indian", "kings indian defense", etc. all map to the same opening.

### Step 4: Storing in PostgreSQL (`lib/storage/repo_postgres.ml`)

The database schema (`scripts/migrations/0001_init.sql`):

#### PostgreSQL Tables:

1. **`players` table**:
   ```sql
   - id (auto-increment)
   - name (e.g., "Kasparov, Garry")
   - fide_id (optional)
   - rating_peak
   ```

2. **`games` table** (one row per game):
   ```sql
   - id
   - white_player_id → references players
   - black_player_id → references players
   - event ("World Championship")
   - site, round, played_on (date)
   - eco_code ("E97")
   - opening_name ("King's Indian Defense, Orthodox Variation")
   - opening_slug ("kings_indian_defense")  ← searchable slug
   - result ("1-0", "0-1", "1/2-1/2")
   - white_rating (2800)
   - black_rating (2750)
   - pgn (full PGN text)
   ```
   **Indexes**: On ratings, ECO codes, opening_slug for fast filtering

3. **`positions` table** (dozens of rows per game):
   ```sql
   - id
   - game_id → references games
   - ply (half-move number: 1, 2, 3...)
   - fen ("rnbqkbnr/pppppppp/...")
   - san ("e4", "Nf3")
   - move_number (full move: 1, 2, 3...)
   - side_to_move ("white" or "black")
   - vector_id (reference to Qdrant, initially NULL)
   ```

4. **`embedding_jobs` table** (queued work):
   ```sql
   - id
   - position_id → references positions
   - fen (the FEN string to embed)
   - status ("pending" → "in_progress" → "completed"/"failed")
   - attempts (retry counter)
   - last_error
   - timestamps (enqueued_at, started_at, completed_at)
   ```

**What happens during ingestion** (`lib/cli/ingest_command.ml:47-68`):
1. Upsert players (avoid duplicates by name/FIDE ID)
2. Insert game record
3. For each move, insert position + enqueue embedding job (but aborts early if the
   pending queue already exceeds `CHESSMATE_MAX_PENDING_EMBEDDINGS` — default 250k).
4. Print: "Stored game 42 with 77 positions"

> Guard rail: the CLI checks `CHESSMATE_MAX_PENDING_EMBEDDINGS` (default 250k) before inserting
> new jobs. Raise or disable this value only when you are certain the embedding workers can keep up.

---

## Part 2: Embedding Pipeline - Creating Vector Representations

### Step 5: The Embedding Worker (`services/embedding_worker/embedding_worker.ml`)

This is a **background service** that runs continuously (pass `--workers N` to run multiple loops in one process):

```ocaml
let rec work_loop repo embedding_client ~poll_sleep =
  match claim_pending_jobs repo ~limit:16 with
  | Ok jobs -> List.iter jobs ~f:(process_job repo embedding_client)
  | Error _ -> sleep and retry
```

Every 2 seconds, it:

1. **Atomically claims** pending jobs (limit 16) – rows transition from `pending` to `in_progress` using `FOR UPDATE SKIP LOCKED`, so multiple workers can run without duplicating work.
2. **Calls OpenAI API** (`lib/embedding/embedding_client.ml:75-93`):
   ```json
   POST https://api.openai.com/v1/embeddings
   {
     "model": "text-embedding-3-small",
     "input": ["rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1"]
   }
   ```
   Returns a **1536-dimensional vector**: `[0.023, -0.451, 0.882, ...]`

3. **Derives a deterministic `vector_id`** from the FEN (SHA digest today) and *marks the job completed*. At present the raw vector is still ignored; wiring up `Repo_qdrant.upsert_points` is tracked in follow-up work.

4. **Updates PostgreSQL**:
   - Set `positions.vector_id = "abc123"` (reserve the identifier for when the vector store comes online)
   - Mark the job as completed and clear `last_error`

> Need to see progress in real time? Run `scripts/embedding_metrics.sh --interval 120`
> to print queue depth, throughput, and a back-of-the-envelope ETA while the worker runs.

### What Goes Where: PostgreSQL vs Qdrant

| Data Type | PostgreSQL | Qdrant |
|-----------|-----------|--------|
| **Player info** | ✅ Full records | ❌ Just names in payload |
| **Game metadata** | ✅ Full records (event, date, result, ECO) | ❌ |
| **Positions (FEN/SAN)** | ✅ Full records | ❌ |
| **Vector embeddings** | ❌ | ⚠️ Reserved via `vector_id`; live uploads coming next |
| **Searchable payload** | ❌ | ⚠️ Planned: denormalized metadata alongside vectors |
| **Linking** | `vector_id` reserved | `game_id` → PostgreSQL |

**Why two databases?**
- **PostgreSQL**: Fast structured queries ("games where white rating > 2700 AND eco = 'E97'")
- **Qdrant**: Fast semantic similarity ("positions similar to this endgame")
- **Hybrid**: Combine both for powerful queries

---

## Part 3: Natural Language Search - From Query to Results

### Step 6: Intent Analysis (`lib/query/query_intent.ml`)

When you search: **"Find King's Indian games where White is 2500 and Black 100 points lower"**

The system extracts:

1. **Normalize text** (line 58-65):
   ```
   "find kings indian games where white is 2500 and black 100 points lower"
   ```

2. **Extract limit** (line 85-103):
   - Looks for patterns: "find 5 games", "top 10", "show three"
   - Result: `limit = 5` (default)

3. **Extract opening filters** (line 119-138):
   - Checks opening catalogue for substring matches
   - "kings indian" → matches `King's Indian Defense`
   - Creates filters:
     ```ocaml
     { field = "opening", value = "kings_indian_defense" }
     { field = "eco_range", value = "E60-E99" }
     ```

4. **Extract rating filters** (line 161-248):
   - Parses "white is 2500" → `white_min = Some 2500`
   - Parses "100 points lower" → `max_rating_delta = Some 100`
   - Result:
     ```ocaml
     { white_min = Some 2500
     ; black_min = None
     ; max_rating_delta = Some 100 }
     ```

5. **Extract keywords** (line 150-159):
   - Removes stopwords ("find", "where", "is", "and")
   - Result: `["kings", "indian", "white", "black", "points", "lower"]`

6. **Detect phases/themes** (line 119-138):
   - "endgame" → `{ field = "phase", value = "endgame" }`
   - "queenside majority" → `{ field = "theme", value = "queenside_majority" }`

**Output plan**:
```ocaml
{
  cleaned_text: "find kings indian games where white is 2500...",
  limit: 5,
  filters: [
    { field: "opening", value: "kings_indian_defense" },
    { field: "eco_range", value: "E60-E99" }
  ],
  rating: { white_min: Some 2500, black_min: None, max_rating_delta: Some 100 },
  keywords: ["kings", "indian", "white", "black", ...]
}
```

---

### Step 7: Hybrid Retrieval (`lib/query/hybrid_executor.ml`)

Now the system fetches data from **both** databases:

#### 7a. PostgreSQL Retrieval (`lib/storage/repo_postgres.ml:293-307`)

```sql
SELECT g.id, w.name, b.name, g.result, g.event, g.opening_slug,
       g.eco_code, g.white_rating, g.black_rating
FROM games g
LEFT JOIN players w ON g.white_player_id = w.id
LEFT JOIN players b ON g.black_player_id = b.id
WHERE g.opening_slug = 'kings_indian_defense'
  AND g.eco_code >= 'E60' AND g.eco_code <= 'E99'
  AND g.white_rating >= 2500
  AND g.white_rating IS NOT NULL
  AND g.black_rating IS NOT NULL
  AND ABS(g.white_rating - g.black_rating) <= 100
ORDER BY g.played_on DESC
LIMIT 50;  -- Overfetch for reranking
```

Returns: **List of game summaries** (metadata only, no positions yet)

#### 7b. Qdrant Vector Search (`lib/storage/repo_qdrant.ml:101-134`)

1. **Build query vector** (`lib/query/hybrid_planner.ml:83-95`):
   - Hash keywords into an 8-dimensional vector (current implementation)
   - Upgrading this step to real OpenAI query embeddings is tracked in the roadmap
   - Result: `[0.65, 0.23, -0.41, ...]`

2. **Build payload filters** (`lib/query/hybrid_planner.ml:69-76`):
   ```json
   {
     "must": [
       { "key": "opening_slug", "match": { "value": "kings_indian_defense" }},
       { "key": "white_elo", "range": { "gte": 2500 }},
       { "key": "black_elo", "range": { "gte": 0 }}
     ]
   }
   ```

3. **Search Qdrant** (when `QDRANT_URL` is configured):
   ```json
   POST /collections/positions/points/search
   {
     "vector": { "name": "default", "vector": [0.65, 0.23, ...] },
     "filter": { ... },
     "limit": 100,
     "with_payload": true
   }
   ```

   Returns: **List of scored vectors**:
   ```json
   [
     { "id": "abc123", "score": 0.92,
       "payload": { "game_id": 42, "white_name": "Kasparov", ... }},
     { "id": "def456", "score": 0.87,
       "payload": { "game_id": 73, "white_name": "Anand", ... }},
     ...
   ]
   ```

   If Qdrant is unreachable (or the env var is unset) the executor records a warning and falls back to the metadata-only heuristic from step 7a, so searches remain usable—just less semantically rich.

---

### Step 8: Combining & Reranking Results (`lib/query/hybrid_executor.ml:168-202`)

Now we have:
- **PostgreSQL results**: 50 games matching metadata filters
- **Qdrant results**: 100 positions (with game_id) matching vector similarity

**How they're combined**:

1. **Index vector hits by game_id** (line 193):
   ```ocaml
   Map { 42 → score=0.92, 73 → score=0.87, ... }
   ```

2. **For each PostgreSQL game** (line 195-198):
   - Look up vector hit (if any) by `game_id`
   - Calculate **hybrid score** (line 130-134):

   ```ocaml
   let score_result plan summary vector_hit =
     (* Vector score: from Qdrant similarity OR fallback heuristic *)
     let vector =
       match vector_hit with
       | Some hit → normalize(hit.score)  # e.g., 0.92
       | None → fallback_heuristic()       # e.g., 0.6
     in

     (* Keyword score: overlap between query keywords and game metadata *)
     let keyword =
       matching_keywords / total_keywords  # e.g., 4/7 = 0.57
     in

     (* Weighted combination: 70% vector + 30% keyword *)
     let combined = (0.7 * vector) + (0.3 * keyword) in
     (combined, vector, keyword)
   ```

   **Example**:
   - Game #42 (Kasparov vs Karpov):
     - Vector score: 0.92 (very similar position)
     - Keyword score: 0.71 (5/7 keywords match)
     - **Total: 0.857**

   - Game #73 (Anand vs Carlsen):
     - Vector score: 0.87
     - Keyword score: 0.43
     - **Total: 0.738**

3. **Sort by total score** (line 199):
   ```ocaml
   List.sort ~compare:(fun a b -> Float.compare b.total_score a.total_score)
   ```

4. **Take top N** (line 201):
   ```ocaml
   List.take scored_results plan.limit  (* 5 games *)
   ```

---

### Step 9: Formatting Results (`lib/query/result_formatter.ml`)

Final output (JSON or text):
```json
{
  "question": "Find King's Indian games where White is 2500 and Black 100 points lower",
  "plan": {
    "filters": [
      { "field": "opening", "value": "kings_indian_defense" },
      { "field": "eco_range", "value": "E60-E99" }
    ],
    "rating": { "white_min": 2500, "max_rating_delta": 100 },
    "limit": 5
  },
  "results": [
    {
      "game_id": 42,
      "white": "Kasparov, Garry",
      "black": "Karpov, Anatoly",
      "white_rating": 2800,
      "black_rating": 2750,
      "result": "1-0",
      "event": "World Championship",
      "opening": "King's Indian Defense",
      "eco_code": "E97",
      "score": 0.857,
      "vector_score": 0.92,
      "keyword_score": 0.71,
      "synopsis": "Kasparov's King's Indian features aggressive pawn storms..."
    }
  ]
}
```

---

## Data Flow Diagram

```
┌─────────────┐
│  PGN File   │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────┐
│  1. Parse PGN               │
│  2. Generate FENs (per ply) │
│  3. Extract opening/ratings │
└──────┬──────────────────────┘
       │
       ├──────────────────────────┐
       │                          │
       ▼                          ▼
┌──────────────┐      ┌────────────────────┐
│ PostgreSQL   │      │ Embedding Jobs     │
│ - players    │      │ (queued for worker)│
│ - games      │      └─────────┬──────────┘
│ - positions  │                │
└──────┬───────┘                │
       │                        ▼
       │              ┌──────────────────┐
       │              │ Embedding Worker │
       │              │ 1. Poll jobs     │
       │              │ 2. Call OpenAI   │
       │              │ 3. Store vectors │
       │              └────┬─────────┬───┘
       │                   │         │
       │                   │         ▼
       │                   │   ┌──────────┐
       │                   │   │  Qdrant  │
       │                   │   │ (vectors)│
       │                   │   └──────────┘
       │                   │
       │                   ▼
       │            (update vector_id)
       │                   │
       └───────────────────┘

┌─────────────────────────────┐
│  SEARCH QUERY               │
│  "Find King's Indian games" │
└──────────┬──────────────────┘
           │
           ▼
┌───────────────────────────┐
│  Query Intent Analysis    │
│  - Extract filters        │
│  - Parse ratings          │
│  - Extract keywords       │
└──────┬────────────────────┘
       │
       ├──────────────┬──────────────┐
       │              │              │
       ▼              ▼              ▼
┌──────────┐   ┌──────────┐   ┌──────────┐
│PostgreSQL│   │  Qdrant  │   │ Combine  │
│ Metadata │   │  Vector  │──▶│  Results │
│  Query   │──▶│  Search  │   │  Rerank  │
└──────────┘   └──────────┘   └────┬─────┘
                                   │
                                   ▼
                            ┌─────────────┐
                            │ Top 5 Games │
                            └─────────────┘
```

---

## Summary: Key Takeaways

1. **PostgreSQL** stores structured data (games, players, positions) - fast for exact filtering.
2. **Qdrant** integration is prepared but not yet receiving live vectors; the worker reserves `vector_id`s so uploads can be enabled without reingesting.
3. **Hybrid search** combines metadata filters with vector similarity when Qdrant replies; otherwise it gracefully falls back to heuristics.
4. **Reranking** uses weighted scoring (70% vector, 30% keyword) whenever vector scores are available.
5. **Every position** (not just games) becomes addressable, enabling “find this board shape” queries.
6. **No LLMs in query processing**—intent parsing relies on deterministic rules and the opening catalogue.

This architecture enables queries like "French Defense endgames that end in a draw with queenside pawn majority" by:
- **Filtering**: opening=french, result=draw, phase=endgame (PostgreSQL)
- **Similarity**: positions resembling "queenside pawn majority" (Qdrant vectors)
- **Combining**: games matching both criteria, ranked by total score

---

## Code References

Key modules implementing each stage:

| Stage | Module | Key Functions |
|-------|--------|---------------|
| **PGN Parsing** | `lib/chess/pgn_parser.ml` | `parse`, `fold_games` |
| **FEN Generation** | `lib/chess/pgn_to_fen.ml` | `fens_of_moves`, `apply_san` |
| **Opening Catalogue** | `lib/chess/openings.ml` | `filters_for_text`, `slug_of_eco` |
| **Postgres Storage** | `lib/storage/repo_postgres.ml` | `insert_game`, `search_games` |
| **Ingestion** | `lib/cli/ingest_command.ml` | `run` |
| **Embedding Client** | `lib/embedding/embedding_client.ml` | `embed_fens` |
| **Embedding Worker** | `services/embedding_worker/embedding_worker.ml` | `work_loop`, `process_job` |
| **Qdrant Storage** | `lib/storage/repo_qdrant.ml` | `upsert_points`, `vector_search` |
| **Intent Analysis** | `lib/query/query_intent.ml` | `analyse`, `parse_rating` |
| **Hybrid Planner** | `lib/query/hybrid_planner.ml` | `build_payload_filters`, `query_vector` |
| **Hybrid Executor** | `lib/query/hybrid_executor.ml` | `execute`, `score_result` |
| **Result Formatting** | `lib/query/result_formatter.ml` | Format results for CLI/API |

---

## Future Enhancements

Current limitations and planned improvements:

1. **Persist embeddings to Qdrant**: Teach the worker to call `Repo_qdrant.upsert_points` so the reserved `vector_id`s reference real vectors.
2. **Reciprocal Rank Fusion (RRF)**: Introduce a more robust result-merging algorithm.
3. **Query Embedding**: Embed user queries (not just keywords) for better semantic matching.
4. **Position Features**: Extract tactical themes (pins, forks, sacrifices) during ingestion.
5. **Caching**: Redis layer for frequently asked questions.
6. **Observability**: Structured logging + Prometheus metrics for worker/API performance.
