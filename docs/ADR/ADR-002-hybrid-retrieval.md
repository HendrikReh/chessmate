# ADR-002 – Hybrid Retrieval Strategy

- **Status**: Accepted
- **Date**: 2025-04-22
- **Related**: GH-007, GH-013, GH-021

## Context
Initial prototypes tried pure keyword search (Postgres full-text) and pure vector search (Qdrant) for answering chess questions. Keyword-only missed semantically similar games; vector-only often surfaced contextually correct but rules-violating matches (wrong players, tournaments). Additionally, the planned GPT-5 agent needed structured candidates with metadata to produce useful explanations.

## Decision
Adopt a three-stage hybrid retrieval pipeline:
1. **Intent analysis** – parse query into filters, keywords, rating ranges.
2. **Candidate generation** – parallel keyword search (Postgres) and vector search (Qdrant) with fallback to metadata-only when vector service is unavailable.
3. **Ranking** – combine scoring heuristics (vector, keyword, metadata boosts) and optionally pass top-K to the GPT-5 agent for re-ranking.

## Consequences
- Positive:
  - Resilient to individual subsystem failures (can serve results without vectors or agent).
  - Supports precise filtering (event, opening, rating) while still leveraging semantic similarity.
  - Provides structured candidates the agent can reason about, keeping GPT usage bounded.
- Negative / Trade-offs:
  - More complexity in orchestration and scoring; requires tests across fallbacks.
  - Additional operational surface (Postgres + Qdrant + optional GPT-5).
- Follow-ups:
  - Continue refining scoring weights and telemetry to detect regressions.
  - Ensure health endpoints report which stage is degraded.

## Alternatives Considered
1. **Keyword-only** – + Simple infra. − Poor semantic recall, struggles with paraphrased questions.
2. **Vector-only** – + Good semantic recall. − Hard to enforce metadata filters and deterministic guarantees.

## Notes
The architecture informed config layout (`Config.Api`) and telemetry (agent, vector fallback warnings). Future enhancements (e.g., reranking weights, personalization) should still preserve the resilient fallback path.
