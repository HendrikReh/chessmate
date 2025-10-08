# Troubleshooting

Common symptoms, quick diagnostics, and proven fixes for keeping Chessmate healthy.

## Quick Smoke Test
Run this loop whenever you reset dependencies or suspect ingest/embedding is wedged. Use
`scripts/embedding_metrics.sh` between steps to verify queue health and estimated finish times.

1. **Check Postgres connectivity**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
   psql postgres://chess:chess@localhost:5433/chessmate -c "SELECT 1"
   ```
2. **Ingest a known-good PGN** (TWIC 1611 ships with the repo fixtures)
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
   dune exec chessmate -- ingest data/games/twic1611.pgn
   ```
3. **Confirm positions land with vector stubs**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
   psql postgres://chess:chess@localhost:5433/chessmate \
   -c "SELECT COUNT(*) FROM positions WHERE vector_id IS NOT NULL"
   ```
4. **Start the embedding worker with exported env**
   ```sh
   set -a
   source .env
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
   QDRANT_URL=http://localhost:6333 dune exec embedding_worker -- --workers 3 --poll-sleep 1.0
   ```
   Adjust `--workers`/`--poll-sleep` based on throughput. (Value of 3 works well on a laptop.)
5. **Watch the queue drain**
   ```sh
   DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
   psql postgres://chess:chess@localhost:5433/chessmate \
   -c "SELECT status, COUNT(*) FROM embedding_jobs GROUP BY status ORDER BY status"
   ```
   `pending` should drop while `completed` rises. If logs still show `Malformed job row`, pull the latest code - psql now emits real tab delimiters so rows parse correctly.

## PGN Ingestion

### Invalid UTF-8 while ingesting TWIC dumps
- **Symptom** `psql ... invalid byte sequence for encoding "UTF8"` during `chessmate ingest`.
- **Cause** Many public PGNs (including TWIC) ship as Windows-1252.
- **Fix** Re-encode before ingestion:
  ```sh
  iconv -f WINDOWS-1252 -t UTF-8//TRANSLIT data/games/twic1611.pgn > /tmp/twic1611.utf8.pgn
  cp /tmp/twic1611.utf8.pgn data/games/twic1611.pgn
  ```
  Transliteration keeps smart quotes/dashes readable. Re-run ingest afterwards.

### Ingestion aborts with "PGN contained no moves"
- **Symptom** Errors such as `PGN game #315 "PGN contained no moves"`.
- **Fix** Run the preflight command to surface bad blocks:
  ```sh
  dune exec chessmate -- twic-precheck data/games/twic1611.pgn
  ```
  The report names each offender (missing `[Result]`, editorial fragments, etc.). Clean up the flagged entries, then re-run ingestion - completed games remain in Postgres.

### Only the first game ingests
- **Symptom** Log stops at `Stored game 3 with 65 positions` despite a large source file.
- **Fix** Update to the multi-game ingest (already merged). Ensure you are running the latest binary; legacy builds processed a single game.

## Environment Setup

### opam cannot open `config.lock`
- **Symptom** `opam: "open" failed on ... config.lock: Operation not permitted`.
- **Fix** Some shells sandbox writes. Run `eval $(opam env --set-switch)` (or `opam env --set-switch | source`) instead of `opam switch set .`.

### `chessmate_api` executable not found
- **Symptom** `Program 'chessmate_api' not found!` when starting the API via Dune.
- **Fix** Use the public name `dune exec -- chessmate-api --port 8080` or the full path `dune exec services/api/chessmate_api.exe -- --port 8080`.

## Database & Vector Stores

### `/query` responses show "Vector search unavailable"
- **Symptom** API replies only contain SQL fallbacks with warnings.
- **Fix** Ensure `QDRANT_URL` points to a reachable instance. The API degrades gracefully but warns until vector search returns.

### Embedding jobs never leave `pending`
- **Symptom** Queue size grows, worker logs stay quiet.
- **Fix** Confirm the worker is running with valid env:
  ```sh
  dune exec chessmate -- embedding-worker
  ```
  Double-check `OPENAI_API_KEY` and endpoint settings. When the worker logs `Malformed job row`, update to the latest code (psql field separator fix). While triaging, run
  ```sh
  DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
    scripts/embedding_metrics.sh --interval 120
  ```
  to ensure new completions are flowing; a flat `throughput/min` indicates the worker is stuck before reaching OpenAI.

### Worker runs but positions miss vectors
- **Symptom** `/query` keeps warning about missing vectors even though the worker is active.
- **Fix** Validate the pipeline end-to-end:
  1. **Queue depth**
     ```sh
     DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     psql postgres://chess:chess@localhost:5433/chessmate \
     -c "SELECT status, COUNT(*) FROM embedding_jobs GROUP BY status"
     ```
     `pending` should fall while `completed` rises.
  2. **Postgres vector IDs**
     ```sh
     DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
     psql postgres://chess:chess@localhost:5433/chessmate \
     -c "SELECT COUNT(*) FROM positions WHERE vector_id IS NOT NULL"
     ```
     Non-zero counts mean vectors are being attached.
  3. **Qdrant collection**
     ```sh
     curl "$QDRANT_URL/collections/positions/points/count"
     ```
     Expect a positive count; zero implies vectors were not pushed.
  If any checkpoint flatlines, inspect worker logs for rate limits or credential issues.

### Agent evaluation returns warnings
- **Symptom** API/CLI responses include warnings such as `Agent evaluation failed` or lack `agent_score` even though the key is set.
- **Fix**
- Confirm `AGENT_API_KEY` and internet access; GPT-5 errors surface in the warning message.
- Ensure `AGENT_REASONING_EFFORT` is valid (`minimal|low|medium|high`) and that the API key has access to the selected model.
- Inspect `[agent-telemetry]` JSON lines for latency, token usage, and cost estimates—persistent spikes or missing usage often explain slowdowns and quota overruns.
- If a cache is enabled (`AGENT_CACHE_CAPACITY`), stale responses can persist until the cache evicts entries—drop the capacity or restart the API to clear it after schema/prompt changes.
- When the agent is temporarily disabled, results fall back to heuristic scoring—address the warning before relying on explanations.

## Queue Management
- **Monitor continuously.** `scripts/embedding_metrics.sh --interval 120 --log logs/embedding-metrics.log`
- **Scale workers safely.** Prefer a single process with multiple loops:
  ```sh
  set -a
  source .env
  DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate \
  QDRANT_URL=http://localhost:6333 dune exec embedding_worker -- --workers 3 --poll-sleep 1.0
  ```
  Increase `--workers` gradually (or stagger extra processes if you must) and watch
  `scripts/embedding_metrics.sh` for rising throughput or new failures (429s, connection drops).
- **Prune stale jobs.** When re-ingesting PGNs, run `scripts/prune_pending_jobs.sh 2000`
  to mark pending jobs whose positions already hold a `vector_id` as completed before
  queueing more work.
- **Throttle ingest automatically.** The ingest CLI now enforces a guard based on
  `CHESSMATE_MAX_PENDING_EMBEDDINGS` (default 250000). Set it to a higher value to push
  more load, or `0`/negative to disable the guard entirely.

## CLI Tips
- Always export `DATABASE_URL` before running ingest/query commands.
- `dune exec chessmate -- help` lists all subcommands and options.

Keep extending this guide as new issues surface - sharable fixes save the whole team time.
