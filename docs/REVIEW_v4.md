# Chessmate Roadmap (v4)

_Last revised: 2025-10-10 (post-v0.6.2 release)_

Chessmate is production-capable, but a few infrastructure gaps remain before we can expose the API broadly. This document tracks what’s done, what’s next, and the effort involved.

---

## 1. Current State

### Shipped in v0.6.2
- Token-bucket API rate limiting (per-IP 429s, Prometheus counters).
- Automatic Qdrant collection bootstrap (API & worker ensure schema on startup).
- Config/documentation refresh covering rate limits and Qdrant settings.

### Shipped in v0.6.1
- CLI health checks prior to queries (Postgres, Qdrant, Redis, API).
- JSON output mode for `chessmate query`.
- Roadmap/doc rewrites; SQL whitespace fix eliminating `DESCLIMIT` errors.

### Shipped in v0.6.0
- Caqti migration (parameterised queries, typed pool).
- Embedding worker uploads vectors with retry/backoff & metadata enrichment.
- Secret sanitisation (API keys, database URLs) and basic `/metrics` gauges.

### Remaining Gaps
| Priority | Issue | Risk |
| --- | --- | --- |
| 🟢 Resolved | API rate limiting | Abuse was exhausting quotas; now enforced |
| 🟢 Resolved | Qdrant bootstrap missing | No more manual curl init |
| 🟡 High | Sparse metrics | No request latency/error tracking |
| 🟡 High | Shallow health checks | `/health` doesn’t verify dependencies |
| 🟡 High | Agent evaluation timeout missing | Slow GPT-5 calls wedge requests |
| 🟡 High | Query pagination absent | Large result sets risk OOM |

---

## 2. Planned Work

### Phase 1 – High Priority
1. **Prometheus metrics expansion** (ETA: ~14h)
   - Instrument request latency histograms, error rates, agent cache hits/misses, embedding throughput.
   - Introduce a metrics helper module so instrumentation stays consistent.

2. **Deep health checks** (ETA: ~8h)
   - Implement `lib/api/health` with probes for Postgres, Qdrant (`/healthz`), Redis (`PING`), and a lightweight OpenAI sanity check.
   - `/health` returns structured JSON (status + per-dependency details); worker exposes the same endpoint.
   - Record probe latency and add `health_dependency_status{service="..."}` metrics.
   - Unit/integration tests cover success/failure paths; load test triggers degraded alerts.

3. **Agent evaluation timeout + circuit breaker** (ETA: ~6h)
   - Add configurable timeout (`AGENT_REQUEST_TIMEOUT_SECONDS`) and wrap GPT-5 calls in `Lwt_unix.with_timeout`.
   - Circuit breaker: after N consecutive failures/timeouts, disable agent calls for a cool-off window (log `[agent-circuit] open/closed`).
   - Fallback response includes warnings (`"agent": {"status": "timeout", "fallback": "heuristic"}`) and increments timeout counters.
   - Tests simulate slow/failed GPT-5 responses and ensure fallback executes.

4. **Query pagination** (ETA: ~12h)
   - Add `limit`/`offset` support to SQL, API schema, CLI options; preserve default limit of 50.

### Phase 2 – Medium Priority (v0.7+)
- Enhanced load-test harness with alert thresholds.
- Snapshot/version embedding collections for reindexing.
- Workflow to reingest/repair orphaned vectors.
- CLI telemetry improvements (structured JSON logs, request IDs).
- Sandbox toggle for simulated agent responses (demo mode).

---

## 3. Effort Summary
| Priority | Tasks | Est. Hours |
| --- | --- | --- |
| High | 4 | 40–50 |
| Medium | 5 | 45–60 |
| Low | 4 | 24–32 |
| **Total** | **13** | **109–142** |

Focus on the high-priority bucket before widening API access.

---

## 4. References
- [ARCHITECTURE.md](ARCHITECTURE.md) – component/data flow diagrams.
- [DEVELOPER.md](DEVELOPER.md) – setup, CLI usage, configuration knobs.
- [docs/cli.mld](cli.mld) – odoc-rendered CLI reference.
- [OPERATIONS.md](OPERATIONS.md) – runbooks, monitoring, incident response.

Questions or contributions? Comment here or open a tracking issue so we keep the roadmap fresh.
