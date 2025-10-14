# Chessmate Roadmap (v5)

_Last revised: 2025-10-13 (comprehensive codebase audit)_

Chessmate is production-capable with a mature, well-architected codebase. This revision incorporates a comprehensive code review identifying critical bugs, architectural improvements, and optimization opportunities alongside the existing roadmap. The high-priority infrastructure gaps remain the focus before widening API access.

---

## 1. Current State

### Shipped in v0.6.3
- PGN parser tolerates percent-style comments and SAN annotations (`?!`, `!!`) without breaking ingestion.
- GPT-5 agent client consumes `output_text` responses and maintains deterministic rate-limit metrics for observability.
- Metadata normalisation trims tags, pads partial dates, and adds annotated PGN regression coverage.

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

### Code Quality Assessment
The codebase demonstrates:
- ✅ Strong functional programming practices (immutability, combinators, `Or_error.t`)
- ✅ Type-safe SQL via Caqti (parameterized queries throughout)
- ✅ Comprehensive error handling with sanitization
- ✅ Good separation of concerns (pure chess logic isolated from IO)
- ✅ Extensive documentation and runbooks
- ⚠️ Some modules missing `.mli` interface files
- ⚠️ Minor inconsistencies in copyright headers

### Critical Issues Identified
| Priority | Issue | Location | Risk |
| --- | --- | --- | --- |
| 🔴 Critical | Race condition in rate limiter bucket pruning | `lib/api/rate_limiter.ml:77` | Data corruption under load |
| 🔴 Critical | Missing agent evaluation timeout | `lib/query/agent_evaluator.ml:164` | Slow GPT-5 calls wedge requests |
| 🟡 High | Sparse metrics (no latency histograms) | `/metrics` endpoint | Can't detect performance degradation |
| 🟡 High | Shallow health checks | `/health` endpoint missing | Can't verify dependencies |
| 🟡 High | Query pagination absent | `lib/storage/repo_postgres_caqti.ml` | Large result sets risk OOM |
| 🟡 High | Worker batch size hard-coded | `services/embedding_worker/embedding_worker.ml:248` | Inflexible under varying loads |
| 🟠 Medium | Embedding model hard-coded | `lib/embedding/embedding_client.ml:85` | Can't switch to newer models |
| 🟠 Medium | Qdrant retry config hard-coded | `services/embedding_worker/embedding_worker.ml:109-112` | Inconsistent with OpenAI retry pattern |
| 🟠 Medium | Request body size unlimited | `services/api/chessmate_api.ml` | Potential DoS vector |

---

## 2. Planned Work

### Phase 0 – Critical Bug Fixes (NEW)
**Priority: Immediate** | **ETA: ~8h**

1. **Fix rate limiter race condition** (ETA: ~2h)
   - **Issue**: `Hashtbl.filteri_inplace` in `prune_if_needed` can conflict with concurrent `ensure_bucket` calls
   - **Location**: `lib/api/rate_limiter.ml:77`
   - **Fix**: Hold mutex for entire prune operation or redesign with immutable data structures
   - **Test**: Add concurrent access test simulating multiple IPs under load

2. **Implement agent evaluation timeout** (ETA: ~4h)
   - **Issue**: GPT-5 calls lack timeout, blocking query pipeline
   - **Location**: `lib/query/agent_evaluator.ml:164`
   - **Fix**: Wrap `Agents_gpt5_client.generate` with `Lwt_unix.with_timeout`
   - **Config**: Add `AGENT_REQUEST_TIMEOUT_SECONDS` (default: 15s)
   - **Fallback**: Return heuristic-only results with warning in JSON response
   - **Test**: Simulate slow agent responses and verify timeout behavior

3. **Validate worker batch size** (ETA: ~1h)
   - **Issue**: Hard-coded 16-job batch could exceed limits during shutdown
   - **Location**: `services/embedding_worker/embedding_worker.ml:248`
   - **Fix**: Add `CHESSMATE_WORKER_BATCH_SIZE` env var with validation
   - **Test**: Verify batch size respected under various exit conditions

4. **Audit SQL injection risks** (ETA: ~1h)
   - **Task**: Review all Caqti query construction for proper parameterization
   - **Focus**: `lib/storage/repo_postgres_caqti.ml` and dynamic SQL building
   - **Expected**: No issues (Caqti enforces parameterization), but verify

### Phase 1 – High Priority Infrastructure
**Priority: Before production rollout** | **ETA: ~40h**

1. **Prometheus metrics expansion** (ETA: ~14h)
   - Instrument request latency histograms (p50, p95, p99)
   - Add error rate counters by endpoint and error type
   - Track agent cache hits/misses with labels
   - Monitor embedding throughput (jobs/minute, char/second)
   - Introduce `lib/api/metrics` helper module for consistency
   - Export circuit breaker state and timeout counts
   - Add `health_dependency_status{service}` gauge for each dependency

2. **Deep health checks** (ETA: ~8h)
   - Implement `lib/api/health` module with dependency probes:
     - Postgres: test query (`SELECT 1`)
     - Qdrant: `/healthz` endpoint check
     - Redis: `PING` command (when configured)
     - OpenAI: lightweight sanity check (optional)
   - `/health` endpoint returns structured JSON:
     ```json
     {
       "status": "healthy|degraded|unhealthy",
       "timestamp": "2025-10-13T12:34:56Z",
       "dependencies": {
         "postgres": {"ok": true, "latency_ms": 12},
         "qdrant": {"ok": true, "latency_ms": 8},
         "redis": {"ok": true, "latency_ms": 2},
         "openai": {"ok": true, "latency_ms": 150}
       }
     }
     ```
   - Worker exposes same endpoint on separate port
   - Unit tests cover success/failure paths
   - Integration tests trigger degraded state and verify fallback

3. **Agent circuit breaker** (ETA: ~6h)
   - Track consecutive agent failures/timeouts
   - Open circuit after N failures (configurable via `AGENT_CIRCUIT_BREAKER_THRESHOLD`, default: 5)
   - Cool-off period before attempting recovery (configurable via `AGENT_CIRCUIT_BREAKER_COOLOFF_SECONDS`, default: 60s)
   - Log circuit state changes: `[agent-circuit] open`, `[agent-circuit] half-open`, `[agent-circuit] closed`
   - Include circuit state in `/health` and `/metrics`
   - JSON responses include circuit status: `{"agent": {"status": "circuit_open", "fallback": "heuristic"}}`
   - Tests simulate cascading failures and verify recovery

4. **Query pagination** (ETA: ~12h)
   - Add `offset` and `limit` parameters to SQL queries
   - API schema accepts `offset` (default: 0) and `limit` (default: 50, max: 500)
   - CLI gains `--offset` and `--limit` flags
   - Response includes pagination metadata:
     ```json
     {
       "offset": 0,
       "limit": 50,
       "total": 1523,
       "has_more": true
     }
     ```
   - Update OpenAPI spec with pagination examples
   - Tests verify boundary conditions (offset > total, limit = 0)

### Phase 2 – Code Quality & Hardening
**Priority: Medium** | **ETA: ~20h**

1. **Configuration enhancements** (ETA: ~5h)
   - Make embedding model configurable: `OPENAI_EMBEDDING_MODEL` (default: `text-embedding-3-small`)
   - Extract Qdrant retry config to use `Common.retry_config` pattern
   - Add `CHESSMATE_WORKER_DB_POOL_SIZE` separate from API pool
   - Make agent candidate limits configurable: `AGENT_CANDIDATE_MULTIPLIER`, `AGENT_CANDIDATE_MAX`
   - Validate Qdrant collection name matches `[a-zA-Z0-9_-]+`

2. **Request security hardening** (ETA: ~4h)
   - Add Opium middleware for max request body size (default: 1MB)
   - Configure via `CHESSMATE_MAX_REQUEST_BODY_BYTES`
   - Return 413 Payload Too Large for violations
   - Add rate limit by body size (e.g., no more than 10MB/minute per IP)

3. **Module interface completeness** (ETA: ~6h)
   - Add `.mli` files for all public modules missing explicit interfaces
   - Focus on `lib/query/*`, `lib/storage/*`, `lib/chess/*`
   - Document public API contracts with module-level docstrings
   - Run `dune build @doc` and verify generated documentation

4. **Copyright header standardization** (ETA: ~1h)
   - Audit all source files for consistent GPL v3 headers
   - Fix shortened header in `lib/query/agent_evaluator.ml:3`
   - Add pre-commit hook to verify headers on new files

5. **Temp file cleanup hardening** (ETA: ~2h)
   - Register embedding client temp files with `at_exit` handler
   - Use `Filename.temp_dir_name` for proper OS-specific temp directory
   - Add signal handlers to clean temp files on SIGTERM/SIGINT

6. **Worker health endpoint** (ETA: ~2h)
   - Add lightweight HTTP server to worker for `/health` and `/metrics`
   - Bind to `CHESSMATE_WORKER_HEALTH_PORT` (default: 8081)
   - Report worker-specific metrics: jobs processed, failures, queue depth

### Phase 3 – Testing & Documentation
**Priority: Medium-Low** | **ETA: ~18h**

1. **Enhanced test coverage** (ETA: ~10h)
   - Integration test for rate limiter (actual API endpoint under load)
   - Load test scenarios with agent evaluation enabled
   - Chaos engineering tests: simulate Qdrant/Postgres/Redis failures
   - Test circuit breaker recovery under various failure patterns
   - Test pagination edge cases (empty results, offset > total)

2. **Documentation infrastructure** (ETA: ~4h)
   - Create `docs/ADR/` directory with template (per GUIDELINES.md)
   - Create `docs/INCIDENTS/` directory with incident report template
   - Document key architectural decisions:
     - ADR-001: Choice of OCaml and functional architecture
     - ADR-002: Hybrid retrieval strategy (deterministic + vector + agent)
     - ADR-003: Token bucket rate limiting approach
     - ADR-004: Caqti migration for SQL safety

3. **Bootstrap script improvements** (ETA: ~2h)
   - Add retry logic for `docker compose up` (wait for services)
   - Verify Postgres/Qdrant/Redis health after startup
   - Print clear error messages if services fail to start
   - Add `--skip-tests` flag for faster iteration

4. **Operational runbooks** (ETA: ~2h)
   - Document circuit breaker recovery procedures
   - Add runbook for agent evaluation timeouts
   - Create incident response checklist
   - Document capacity planning guidelines (pool sizing, worker scaling)

### Phase 4 – Optimizations & Enhancements
**Priority: Low** | **ETA: ~16h**

1. **Performance optimizations** (ETA: ~8h)
   - Cache `rating_matches` result in `hybrid_executor` to avoid duplicate checks
   - Optimize tokenization in `hybrid_executor.ml:98-101` (single-pass)
   - Profile agent evaluation path and optimize hot loops
   - Consider connection pooling for curl-based HTTP calls

2. **Enhanced load testing** (ETA: ~4h)
   - Add alert threshold configurations to load test script
   - Test various agent/vector/keyword weighting scenarios
   - Benchmark embedding worker throughput under different concurrency levels
   - Document performance baselines and regression thresholds

3. **Embedding collection management** (ETA: ~4h)
   - Support snapshot/versioning of Qdrant collections for reindexing
   - Add CLI command: `chessmate collection snapshot --name <name>`
   - Add CLI command: `chessmate collection restore --snapshot <id>`
   - Document workflow for zero-downtime reindexing

---

## 3. Detailed Issue Tracker

### Critical Bugs (Phase 0)

#### BUG-001: Rate Limiter Race Condition
- **Severity**: Critical
- **File**: `lib/api/rate_limiter.ml:77`
- **Description**: `Hashtbl.filteri_inplace` modifies bucket hashtable while potentially being accessed by concurrent `ensure_bucket` calls
- **Impact**: Data corruption, incorrect rate limiting under high concurrency
- **Root Cause**: Mutex released before pruning completes
- **Fix Strategy**: Hold mutex during entire prune or use lock-free data structure
- **Test Plan**: Concurrent access test with 100+ threads hammering rate limiter

#### BUG-002: Missing Agent Timeout
- **Severity**: Critical
- **File**: `lib/query/agent_evaluator.ml:164`
- **Description**: GPT-5 agent calls lack timeout mechanism, can block query pipeline indefinitely
- **Impact**: Single slow agent response wedges entire query processing
- **Root Cause**: No timeout wrapper around `Agents_gpt5_client.generate`
- **Fix Strategy**: Wrap with `Lwt_unix.with_timeout`, implement fallback to heuristic scoring
- **Config**: `AGENT_REQUEST_TIMEOUT_SECONDS` (default: 15)
- **Test Plan**: Mock slow agent responses, verify timeout and fallback behavior

#### BUG-003: Worker Batch Size Unbounded
- **Severity**: High
- **File**: `services/embedding_worker/embedding_worker.ml:248`
- **Description**: Hard-coded batch size of 16 jobs not validated against system capacity
- **Impact**: Could claim more jobs than worker can process during shutdown
- **Root Cause**: No configuration or validation of batch size
- **Fix Strategy**: Add `CHESSMATE_WORKER_BATCH_SIZE` env var with validation
- **Test Plan**: Verify batch size respected under exit-after-empty conditions

### High Priority Issues (Phase 1)

#### ISSUE-001: Sparse Metrics
- **Severity**: High
- **Description**: No request latency histograms, limited error tracking
- **Impact**: Cannot detect performance degradation or diagnose slowdowns
- **ETA**: 14h
- **Dependencies**: None

#### ISSUE-002: Missing Health Endpoint
- **Severity**: High
- **Description**: `/health` endpoint not implemented, can't verify dependency status
- **Impact**: Poor operational visibility, can't integrate with monitoring systems
- **ETA**: 8h
- **Dependencies**: None

#### ISSUE-003: No Query Pagination
- **Severity**: High
- **Description**: Large result sets loaded entirely into memory
- **Impact**: OOM risk for queries matching thousands of games
- **ETA**: 12h
- **Dependencies**: None

#### ISSUE-004: No Circuit Breaker
- **Severity**: High
- **Description**: Agent failures cascade, no automatic recovery
- **Impact**: One flaky agent endpoint can degrade entire service
- **ETA**: 6h
- **Dependencies**: BUG-002 (agent timeout)

### Medium Priority Issues (Phase 2)

#### ISSUE-005: Hard-Coded Embedding Model
- **Severity**: Medium
- **File**: `lib/embedding/embedding_client.ml:85`
- **Description**: Model fixed to `text-embedding-3-small`, can't upgrade to `-large`
- **Impact**: Can't leverage improved embedding models without code change
- **Fix**: Add `OPENAI_EMBEDDING_MODEL` env var

#### ISSUE-006: Qdrant Retry Config Inconsistent
- **Severity**: Medium
- **File**: `services/embedding_worker/embedding_worker.ml:109-112`
- **Description**: Qdrant retries use hard-coded values, OpenAI uses config pattern
- **Impact**: Inconsistent retry behavior, harder to tune for production
- **Fix**: Refactor to use `Common.retry_config`

#### ISSUE-007: Request Body Size Unlimited
- **Severity**: Medium
- **File**: `services/api/chessmate_api.ml`
- **Description**: No middleware limiting request body size
- **Impact**: Large POST bodies could DoS the service
- **Fix**: Add Opium middleware with configurable limit

#### ISSUE-008: Missing Module Interfaces
- **Severity**: Medium
- **Description**: Some modules lack `.mli` files (violates GUIDELINES.md)
- **Impact**: Harder to understand public API, risks accidental breaking changes
- **Fix**: Add `.mli` for all public modules, document contracts

### Low Priority Issues (Phase 4)

#### ISSUE-009: Suboptimal Vector Score Calculation
- **Severity**: Low
- **File**: `lib/query/hybrid_executor.ml:133-142`
- **Description**: `fallback_vector_score` recalculates `rating_matches` redundantly
- **Impact**: Minor performance overhead on every query
- **Fix**: Cache rating match result before branching

#### ISSUE-010: Temp File Cleanup Not Guaranteed
- **Severity**: Low
- **File**: `lib/embedding/embedding_client.ml:133-135`
- **Description**: If process killed during curl, temp files may leak
- **Impact**: Disk space slowly consumed over time
- **Fix**: Register files with `at_exit` handler

---

## 4. Effort Summary

| Phase | Priority | Tasks | Est. Hours |
| --- | --- | --- | --- |
| Phase 0 | Critical | 4 | 8 |
| Phase 1 | High | 4 | 40 |
| Phase 2 | Medium | 6 | 20 |
| Phase 3 | Medium-Low | 4 | 18 |
| Phase 4 | Low | 3 | 16 |
| **Total** | | **21** | **102** |

### Recommended Execution Order
1. **Week 1**: Phase 0 (critical bugs) + Issue-002 (health checks)
2. **Week 2**: Issue-001 (metrics) + Issue-004 (circuit breaker)
3. **Week 3**: Issue-003 (pagination) + Phase 2 (configuration hardening)
4. **Week 4**: Phase 3 (testing & docs)
5. **Week 5+**: Phase 4 (optimizations, as needed)

---

## 5. Testing Strategy

### Unit Tests
- Rate limiter concurrent access (BUG-001)
- Agent timeout and fallback (BUG-002)
- Worker batch size validation (BUG-003)
- Pagination boundary conditions (ISSUE-003)
- Circuit breaker state transitions (ISSUE-004)

### Integration Tests
- End-to-end health checks with simulated failures
- API rate limiting under concurrent load
- Agent evaluation with Redis cache
- Pagination across large datasets

### Load Tests
- Baseline: 60s, 50 concurrent, agent disabled
- Agent path: 60s, 20 concurrent, agent enabled
- Circuit breaker: sustained agent failures, verify recovery
- Pagination: large result sets, verify memory usage

### Chaos Tests
- Kill Postgres mid-query, verify error handling
- Stop Qdrant during vector search, verify fallback
- Redis unavailable, verify cache degrades gracefully
- OpenAI 429 rate limits, verify retry backoff

---

## 6. Security Considerations

### Current State
- ✅ Parameterized SQL queries (Caqti)
- ✅ Secret sanitization in logs
- ✅ Token bucket rate limiting
- ⚠️ API keys in environment (standard but visible in process listings)
- ⚠️ No request body size limits
- ⚠️ Qdrant collection name not validated

### Recommendations
1. **Production**: Integrate secret manager (AWS Secrets Manager, HashiCorp Vault)
2. **Immediate**: Add request body size limits (ISSUE-007)
3. **Short-term**: Validate all user-provided identifiers (collection names, etc.)
4. **Long-term**: Consider mTLS for Qdrant communication

---

## 7. References

### Documentation
- [ARCHITECTURE.md](ARCHITECTURE.md) – component/data flow diagrams
- [DEVELOPER.md](DEVELOPER.md) – setup, CLI usage, configuration knobs
- [OPERATIONS.md](OPERATIONS.md) – runbooks, monitoring, incident response
- [TESTING.md](TESTING.md) – test matrix, fixtures, troubleshooting
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) – common issues and fixes
- [GUIDELINES.md](GUIDELINES.md) – coding standards, PR checklist
- [docs/cli.mld](cli.mld) – odoc-rendered CLI reference

### Related Files
- [REVIEW_v4.md](REVIEW_v4.md) – previous roadmap (superseded)
- [CLAUDE.md](../CLAUDE.md) – guidance for Claude Code instances

---

## 8. Change Log

### v5 (2025-10-13)
- Added Phase 0 for critical bug fixes
- Identified rate limiter race condition (BUG-001)
- Expanded agent timeout work with circuit breaker
- Added 10 new issues from comprehensive code audit
- Reorganized priorities into clearer phases
- Added detailed issue tracker section
- Added testing strategy and security considerations
- Reduced total estimated hours (102h vs 109-142h in v4) through better scoping

### v4 (2025-10-10)
- Post-v0.6.3 release updates
- Focused on infrastructure gaps before production
- 4 high-priority tasks (40-50h)

---

## 9. Success Criteria

### Phase 0 Complete
- ✅ All critical bugs fixed and deployed
- ✅ Race condition test passing under high concurrency
- ✅ Agent timeout test covering slow/failed responses
- ✅ No regressions in existing test suite

### Phase 1 Complete
- ✅ `/health` endpoint returns structured JSON for all dependencies
- ✅ `/metrics` includes request latency histograms (p50, p95, p99)
- ✅ Circuit breaker opens/closes correctly during agent failures
- ✅ Pagination works for result sets up to 10k games
- ✅ Load tests show <2s p95 latency under 50 concurrent users

### Production Ready
- ✅ All Phase 0 and Phase 1 tasks complete
- ✅ Integration tests passing, including chaos scenarios
- ✅ Documentation current (runbooks, ADRs, incident templates)
- ✅ Security hardening complete (body size limits, validation)
- ✅ Monitoring dashboard configured with alerts
- ✅ Incident response procedures documented and tested

---

Questions, bugs, or contributions? Open a tracking issue or PR so we keep the roadmap fresh. This living document will evolve as the codebase matures.
