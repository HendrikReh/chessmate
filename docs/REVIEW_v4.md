# Chessmate Review & Improvement Plan (v4)

_Last revised: 2025-10-10 (post-v0.6.1 health-check release)_

Chessmate is stable enough for production-style workloads, but a handful of infrastructure gaps are blocking public deployment. This document summarises the current state, highlights outstanding issues, and provides an incremental roadmap for closing them.

---

## 1. Current Snapshot

### Completed in v0.6.1
- **CLI health checks** run before queries, verifying Postgres, Qdrant, Redis, and the API.
- **JSON mode** for `chessmate query` supports piping results to tools like `jq`.
- **Review roadmap refresh** consolidates planning notes and follow-up tasks.
- **SQL whitespace fix** eliminates the `DESCLIMIT` error in the default query path.

### Completed in v0.6.0
- **Database layer** migrated to typed Caqti (no more shelling out to `psql`, parameterised queries throughout).
- **Embedding worker** uploads vectors to Qdrant with exponential backoff and metadata enrichment.
- **Secret sanitisation** redacts API keys, Postgres/Redis URLs, and other sensitive strings in logs.
- **Observability foundations**: `/metrics` exposes Caqti pool gauges; load-test script and documentation updated; sanitiser tests and core integration tests in place.

### Major Gaps
| Priority | Issue | Risk |
| --- | --- | --- |
| 🔴 Critical | No API rate limiting | Abuse can exhaust quotas and starve the DB |
| 🔴 Critical | Qdrant collection bootstrap missing | Fresh deployments fail until manually created |
| 🟡 High | Sparse metrics | No request latency, error rates, or cache visibility |
| 🟡 High | Shallow health checks | Current `/health` endpoint doesn’t verify dependencies |
| 🟡 High | Agent evaluation timeout missing | Long-running calls can wedge the request path |
| 🟡 High | Query pagination absent | Large responses risk OOM |


---

## 2. Suggested Roadmap

### Phase 1 – Critical Fixes
1. **API rate limiting**  
   - Implement a token-bucket middleware (per IP, ENV-tuned: `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE`).  
   - Add 429 response to OpenAPI and `/metrics` counter (`api_rate_limited_total`).  
   - Effort: ~12h.

2. **Qdrant collection bootstrap**  
   - Extend `Repo_qdrant` with `ensure_collection`.  
   - Invoke from API and worker startup (before accepting requests/processing jobs).  
   - Support configurable vector size/name (`QDRANT_COLLECTION_NAME`, `QDRANT_VECTOR_SIZE`).  
   - Effort: ~10h.

### Phase 2 – High Priority
3. **Prometheus metrics (v0.6.x)**  
   - Instrument request latency, error rates, agent cache hits/misses, embedding throughput.  
   - Adopt a metrics helper module to keep instrumentation consistent.  
   - Effort: ~14h.

4. **Deep health checks**  
   - Expand `/health` to probe Postgres, Qdrant, Redis, OpenAI; surface degraded states as JSON.  
   - Reuse CLI health-check helper to avoid duplication.  
   - Effort: ~8h.

5. **Agent evaluation timeout**  
   - Configure `Agents_gpt5_client` with per-request timeout and surface retries/failures as structured errors.  
   - Effort: ~6h.

6. **Query pagination**  
   - Add `limit`/`offset` parameters to SQL and API schema.  
   - Preserve default limit of 50; add CLI flags.  
   - Effort: ~12h.

### Phase 3 – Medium Priority (v0.7+)
- Enhanced load-test harness with automated thresholds.
- Snapshot/version embedding collection (support reindexing).
- Workflow to reingest/repair orphaned vectors.
- CLI telemetry improvements (structured JSON logs, tracing IDs).
- Sandbox toggle for simulated agent results (useful for demos).

---

## 3. Outstanding Investments

| Priority | Tasks | Est. Hours |
| --- | --- | --- |
| Critical | 2 | 20–24 |
| High | 4 | 40–50 |
| Medium | 6 | 45–60 |
| Low | 4 | 24–32 |
| **Total** | **16** | **129–166** |

The aim is to close out the critical items before widening API access. Most remaining work is infrastructure-focused; domain logic (parsers, embeddings, agent scoring) is in good shape.

---

## 4. Quick Reference

- `/docs/ARCHITECTURE.md` – detailed diagrams and flow explanations.
- `/docs/DEVELOPER.md` – setup, CLI usage, agent configuration.
- `/docs/cli.mld` – odoc-rendered summary of CLI commands, including health-check behaviour.
- `/docs/OPERATIONS.md` – deployment playbooks, monitoring, and emergency runbooks.

Questions or updates? Append them here or open a tracking issue so we keep the roadmap fresh.
