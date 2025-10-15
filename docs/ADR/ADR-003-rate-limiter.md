# ADR-003 – Token Bucket Rate Limiter

- **Status**: Accepted
- **Date**: 2025-05-03
- **Related**: GH-001, GH-021

## Context
The API needs to protect Postgres/Qdrant and the GPT-5 agent from abusive clients. Early experiments looked at reverse-proxy based rate limiting (NGINX) and Redis-based counters. We wanted per-IP throttling that integrates with metrics and health checks without adding more infrastructure dependencies.

## Decision
Implement an in-process token bucket limiter (`Rate_limiter` module) with the following characteristics:
- Maintains per-IP buckets with refill calculations in OCaml.
- Uses mutex-protected state for thread safety.
- Exposes metrics (`api_rate_limited_total{ip}`) and health integration.
- Middleware wraps Opium routes to return `429` with `Retry-After` headers and logs sanitized route/IP information.

## Consequences
- Positive:
  - Simple deployment: no external cache required.
  - Full control over behaviour (burst size, pruning of stale buckets, metrics).
  - Works in tandem with request body limits and future body-size quotas.
- Negative / Trade-offs:
  - Per-instance limits (no shared state across replicas without additional work).
  - Increases memory usage per active IP; must tune pruning interval/timeout.
- Follow-ups:
  - Consider Redis-backed shared buckets if multi-instance deployments grow.
  - Ensure middleware is applied to relevant routes (POST/GET `/query`).

## Alternatives Considered
1. **NGINX rate limit** – + Offloads to edge. − Harder to integrate with application metrics/health signalling.
2. **Redis Lua script** – + Cluster-aware. − Additional operational dependency, more latency per request.

## Notes
Recent changes added body-size quotas to extend the limiter. Future enhancements should evaluate sharing windows across instances while retaining current observability hooks.
