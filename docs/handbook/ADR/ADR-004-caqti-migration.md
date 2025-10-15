# ADR-004 – Adopt Caqti for Postgres Access

- **Status**: Accepted
- **Date**: 2025-06-15
- **Related**: GH-004, GH-013, GH-021

## Context
Legacy prototypes used ad-hoc SQL string concatenation with `Postgresql` bindings, which made it hard to ensure parameterization and introduced SQL injection risks. We also lacked a consistent story for migrations and schema evolution.

## Decision
Adopt Caqti as the database access layer:
- Define queries using typed `Caqti_request` values with explicit input/output schemas.
- Implement helpers in `Repo_postgres` modules returning `Or_error.t`.
- Use Caqti-blocking backend for simplicity inside worker/API threads.
- Store migrations as SQL files under `scripts/migrations` and apply them in order during setup/CI.

## Consequences
- Positive:
  - Strongly-typed queries prevent injections and mismatched columns.
  - Clear separation between pure chess logic and persistence code.
  - Easier to reuse connections and manage transactions.
- Negative / Trade-offs:
  - Slightly more boilerplate (constructing `Request.(...)` values).
  - Requires familiarity with Caqti’s API and error types.
- Follow-ups:
  - Monitor Caqti performance; consider pooling or async backends if latency becomes significant.
  - Keep migrations idempotent and document rollback plans.

## Alternatives Considered
1. **Direct Postgresql bindings** – + Minimal dependency. − Higher risk of SQL injection, error-prone string handling.
2. **Custom query builder** – + Potentially more ergonomic. − Reinventing wheels, harder to maintain.

## Notes
Caqti adoption ties into our health checks and worker pipeline. Migrations are applied before integration tests and the worker relies on consistent schemas to fetch embedding jobs safely.
