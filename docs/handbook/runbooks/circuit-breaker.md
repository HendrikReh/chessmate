# Circuit Breaker Runbook

_Last updated: 2025-10-15_

## Overview
The agent circuit breaker prevents cascading GPT-5 failures from impacting query latency. It opens when consecutive agent calls fail or exceed timeout thresholds and automatically closes once conditions improve.

## Detection
- **Health endpoint**: `curl -s http://localhost:8080/health | jq '.checks[] | select(.name=="openai")'`
  - `status:"error"` accompanied by `detail` mentioning "circuit_open".
- **Metrics**: `curl -s http://localhost:8080/metrics | grep agent_circuit_breaker_state`
  - `1` indicates open, `0` closed.
- **Logs**: `[agent] circuit breaker opened` and `[agent] circuit breaker closed` entries in API logs.

## Immediate Response
1. **Verify OpenAI status** – check dashboard or `curl` to confirm whether upstream is degraded.
2. **Confirm breaker state**:
   ```sh
   curl -s http://localhost:8080/metrics | grep agent_circuit_breaker_state
   ```
3. **Mitigation options**:
   - Leave breaker open (default) to keep serving heuristic-only results.
   - Reduce agent load by lowering `AGENT_CANDIDATE_MULTIPLIER`/`AGENT_CANDIDATE_MAX`.
   - Increase `AGENT_REQUEST_TIMEOUT_SECONDS` only if upstream latency is temporarily high and acceptable.

## Recovery Steps
1. Ensure upstream GPT-5 service is healthy.
2. If the breaker remains open beyond the configured cool-off window, restart the API process to reset counters (the breaker resets on start-up).
3. Monitor `/metrics` and logs for closure confirmation.

## Follow-up
- Document the incident in `../INCIDENTS/` if user-visible impact occurred.
- Review breaker thresholds (`AGENT_CIRCUIT_BREAKER_THRESHOLD`, `AGENT_CIRCUIT_BREAKER_COOLOFF_SECONDS`) and adjust if triggers were too sensitive or too lax.
- Evaluate whether retries or backoff need tuning (`OPENAI_RETRY_MAX_ATTEMPTS`, `OPENAI_RETRY_BASE_DELAY_MS`).
