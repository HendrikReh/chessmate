# Capacity Planning Runbook

_Last updated: 2025-10-xx_

## Goals
Right-size Postgres, Qdrant, Redis, and worker/API concurrency to meet latency SLOs while keeping resource usage within budget.

## Key Metrics
- **API**: `api_request_latency_ms_p95`, `api_rate_limited_total`, `db_pool_wait_ratio`.
- **Postgres**: `db_pool_in_use`, `db_pool_waiting`, host CPU/IO.
- **Qdrant**: `qdrant_request_duration_seconds`, container CPU/memory.
- **Worker**: `embedding_worker_jobs_per_min`, `embedding_worker_queue_depth`.

## Procedure
1. **Establish Baseline**
   - Run load tests for agent-on and agent-off scenarios (`docs/LOAD_TESTING.md`).
   - Capture metrics snapshots and note throughput/latency.
2. **Evaluate Postgres Pool**
   - If `db_pool_wait_ratio > 0.2` or `waiting > 0`, increase `CHESSMATE_DB_POOL_SIZE` by increments of 5.
   - Monitor `pg_stat_activity` and host CPU; revert if saturation occurs.
3. **Adjust Worker Concurrency**
   - Increase `--workers` gradually while watching queue depth and GPT-5 rate limits.
   - Ensure `embedding_worker_jobs_per_min` scales without sustained `queue_depth` growth.
4. **Rate Limiter Tuning**
   - Set `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` high enough so legitimate load is not throttled during tests; adjust body quotas if large payloads are expected.
5. **Qdrant Resources**
   - If vector searches dominate latency, consider increasing container CPU/memory or enabling Qdrant clustering.
6. **Agent Scaling**
   - For high GPT-5 usage, evaluate caching (`AGENT_CACHE_REDIS_URL`) or sharding API instances behind a load balancer with shared cache.

## Decision Checklist
- Have SLO/SLA thresholds been defined for query p95?
- Are we monitoring circuit breaker and timeout counters post-change?
- Have we documented the new baseline in the load-testing log?

## Follow-up
- Update dashboards with new capacity values.
- Schedule recurring load tests (e.g., monthly) to detect regressions.
- Record changes in relevant ADRs if architecture adjustments were made.
