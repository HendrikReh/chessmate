# Troubleshooting

This guide collects the most common hiccups we have seen while working on Chessmate, along with quick wins to keep you moving.

## PGN Ingestion
- **Symptom:** `psql ... invalid byte sequence for encoding "UTF8"` while running `chessmate ingest` on TWIC bulletins or other third‑party dumps.
  - **Why it happens:** Many public PGNs (including TWIC) ship in Windows‑1252, so Postgres refuses to ingest them once we push the raw text into the database.
  - **Fix:** Re-encode before ingesting:
    ```sh
    iconv -f WINDOWS-1252 -t UTF-8//TRANSLIT data/games/twic1611.pgn > /tmp/twic1611.utf8.pgn
    cp /tmp/twic1611.utf8.pgn data/games/twic1611.pgn
    ```
    The transliteration keeps smart quotes/dashes readable. Once converted, rerun `chessmate ingest` and Postgres will accept the file.
- **Symptom:** `Stored game 3 with 65 positions` when the source PGN holds many games.
  - **Fix:** Upgrade to the multi-game ingest (already merged). Ensure you are running the latest binary; older builds only processed the first game.

## Environment Setup
- **Symptom:** `opam: "open" failed on ... config.lock: Operation not permitted` inside the repo.
  - **Fix:** Some shells block writes when sandboxed. Run `opam env --set-switch | source` instead of `opam switch set .`.
- **Symptom:** `Program 'chessmate_api' not found!` when starting the API via Dune.
  - **Fix:** Use the public name `dune exec -- chessmate-api --port 8080` or the full path `dune exec services/api/chessmate_api.exe -- --port 8080`.

## Database & Vector Stores
- **Symptom:** `/query` responses contain only warnings such as `Vector search unavailable (...).`
  - **Fix:** Ensure `QDRANT_URL` points to a reachable instance. When Qdrant is down the API falls back to SQL results and adds warnings.
- **Symptom:** Ingest jobs stall because embeddings never arrive.
  - **Fix:** Confirm the embedding worker is running (`dune exec embedding_worker`). Check `OPENAI_API_KEY`/endpoint settings and review worker logs for rate-limit messages.

## CLI Tips
- Always export `DATABASE_URL` before running ingest/query commands.
- Use `dune exec chessmate -- help` for a quick recap of available subcommands.

Feel free to extend this document as new issues turn up; keeping symptoms and fixes close at hand saves everyone time.
