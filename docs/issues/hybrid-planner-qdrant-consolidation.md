# Issue: Consolidate Qdrant Hits Per Game in Hybrid Planner

## Summary
- `Hybrid_planner.vector_hits_of_points` converts Qdrant `scored_point`s into the internal `vector_hit` representation, but deduplicates purely via `List.dedup_and_sort` on `game_id`.
- Qdrant can emit multiple points for the same `game_id` (e.g., separate vectors for different move windows). When that happens, the planner keeps only the first point, dropping the higher score and richer metadata from later entries.
- The hybrid executor therefore receives incomplete vector evidence for games that should be highly relevant.

## Impact
- **Ranking quality:** Retaining the first hit rather than the highest score can reorder results unpredictably, allowing lower-quality games to displace stronger matches.
- **Metadata loss:** Downstream keyword/phase/theme merges in `Hybrid_executor` rely on the presence of these fields. Losing them strips context the UI and GPT re-ranker expect.
- **Explainability:** Users receive fewer tagged themes/phases, making it harder to justify why a game surfaced.
- Issue surfaced during the February 2025 planner review; tracked in `PLAN.md`.

## Proposed Fix
- Refactor `Hybrid_planner.vector_hits_of_points` to:
  - Fold over `Repo_qdrant.scored_point`s, grouping by `game_id`.
  - Preserve the maximum `score` seen for each game.
  - Union `phases`, `themes`, and `keywords` with the existing `merge_*` helpers to ensure case-normalised deduplication.
  - Return a stable list (sorted by `game_id` or by final score if we want deterministic ranking).
- Update call sites if the function signature changes (e.g., the executor might prefer `Map.M(Int).t` directly).

## Acceptance Criteria
- Given multiple Qdrant hits for the same `game_id`, the planner returns a single `vector_hit` containing:
  - The highest score observed.
  - The de-duplicated union of phases, themes, and keywords from all contributing hits.
- Hybrid executor results display merged metadata and leverage the highest vector score when ranking.
- Regression test in `test/test_query.ml` fails prior to the change and passes afterward.
- Existing tests continue to pass (`dune runtest`).

## Implementation Notes
- Consider using `Map.reduce_exn` or `Map.update` to combine hits, with a combining function that applies `Float.max` for scores, and the existing `merge_*` helpers for metadata.
- Watch for performance: number of hits is typically small (< 50), so clarity matters more than micro-optimisation.
- Ensure the final list order is deterministic—either sorted by `game_id` or descending by score—to avoid flaky tests and inconsistent API responses.
- Update `Hybrid_executor` tests if assumptions about hit ordering change.

## Testing
- New Alcotest in `test/test_query.ml` (or a dedicated module) that constructs multiple `Repo_qdrant.scored_point`s for one game and asserts merged score/metadata.
- Run `dune runtest --no-buffer` locally; capture output for PR validation.
- Optional: Add property-style test ensuring merges are idempotent (applying the function twice yields same result).

## Additional Context
- Sits alongside planner improvements being tracked in `PLAN.md`.
- Related modules/files:
  - `lib/query/hybrid_planner.ml`
  - `lib/query/hybrid_executor.ml`
  - `test/test_query.ml`
  - Potential follow-on docs updates: `docs/query.mld`
