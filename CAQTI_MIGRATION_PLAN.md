• Here’s a scoped plan for migrating the repository layer to Caqti—broken down package-by-package so we can ship safely:

  ———

  ## Phase 1 – Lay the Groundwork

  1. Add Caqti dependencies: caqti, caqti-driver-postgresql, caqti.blocking.
  2. Introduce a new module (Repo_postgres_caqti) that encapsulates a Caqti_blocking pool, sanitised error handling, and utility helpers (with_connection, stats). Keep the old libpq module in
     place for now.

  ———

  ## Phase 2 – Read-Only Queries

  1. Re-implement non-mutating calls using Caqti:
      - search_games
      - pending_embedding_job_count
      - fetch_games_with_pgn
      - any other read-only lookups (metadata/parsing tests).
  2. Anchor new code under Repo_postgres_caqti; wire the API (and tests) to read from the Caqti version by feature-flag or gradual swap.
  3. Verify parity with integration tests (test/test_integration.ml) and new unit tests for the typed results.

  ———

  ## Phase 3 – Write & Job Operations

  1. Migrate state-changing functions:
      - insert_game
      - insert_positions
      - claim_pending_jobs
      - mark_job_completed, mark_job_failed
      - vector_payload_for_job (if it becomes a more complex Caqti query).
  2. Update worker/ingest command to use the Caqti pool, removing direct libpq references.
  3. Run worker integration tests and the /query integration flow to confirm behaviour.

  ———

  ## Phase 4 – Cutover & Cleanup

  1. Flip production call sites (API/worker/CLI/test) to use the Caqti-backed module exclusively.
  2. Remove the legacy Repo_postgres (libpq) code once parity is confirmed.
  3. Update docs (DEVELOPER.md, OPERATIONS.md) to note the new dependency and any env var changes.
  4. Expand /metrics to surface Caqti pool stats if relevant.

  ———

  ## Phase 5 – Validation & Instrumentation

  1. Run load tests (scripts/load_test.sh) at previous baselines (e.g., 50 concurrent /query requests).
  2. Capture metrics before/after to ensure the pool behaves as expected.
  3. Keep TODO items for longer-term instrumentation (logging query durations, etc.).

  ———

  This staged approach lets us deliver the changes gradually, keeping regression risk and review surface manageable.