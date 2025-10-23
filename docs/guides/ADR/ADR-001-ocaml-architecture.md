# ADR-001 – Adopt OCaml and Functional Architecture

- **Status**: Accepted
- **Date**: 2025-03-12
- **Related**: GH-001, GH-010

## Context
Chessmate needs strong guarantees around correctness, concurrency safety, and predictable performance. Early prototypes explored Python (fast iteration, rich ML ecosystem) and Go (simple deployment, good concurrency primitives). However, both had trade-offs: Python required heavy discipline to avoid runtime errors and lacked static guarantees; Go’s type system and standard library made data-processing pipelines noisy, and its lack of algebraic data types made complex domain modeling cumbersome.

## Decision
Adopt OCaml as the primary implementation language with a functional-first architecture:
- Use `Base/Core` for modern standard library components.
- Model chess/game/query domain entities with immutable records and sum types.
- Encapsulate effects (IO, DB, network) behind modules returning `Or_error.t`.
- Embrace pattern matching and module interfaces (`.mli`) to maintain clear contracts.

## Consequences
- Positive:
  - Strong compile-time guarantees catch many classes of bugs early.
  - Immutable defaults and expressive types make domain logic easier to reason about.
  - Interop with C/FFI is available when performance hotspots demand it.
- Negative / Trade-offs:
  - Smaller hiring pool; onboarding requires OCaml ramp-up.
  - Build tooling (opam, dune) introduces a learning curve and CI considerations.
  - Library ecosystem smaller than Python/Go for some integrations.
- Follow-ups:
  - Invest in documentation and pairing to onboard contributors.
  - Maintain consistent ocamlformat configuration across the repo.

## Alternatives Considered
1. **Python** – + Rapid development, rich libraries. − Weak static guarantees, performance tuning obligatory, difficult error surfaces in concurrency.
2. **Go** – + Easy deployment, straightforward concurrency. − Verbose domain modeling, lack of generics (at the time), limited pattern matching.

## Notes
OCaml’s module system also enables clear boundaries between chess logic, storage, query, and worker subsystems. Future components (embedding, agent integrations) should continue to expose `.mli` contracts for testability.
