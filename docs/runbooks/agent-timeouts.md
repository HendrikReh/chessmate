# Agent Timeout Runbook

_Last updated: 2025-10-xx_

## Symptoms
- API responses include `warnings` such as `agent timeout – falling back to heuristic results`.
- Metrics `agent_timeout_total` incrementing (check `/metrics`).
- Health endpoint shows `openai` check as `degraded` with detail mentioning timeout.

## Triage Checklist
1. **Confirm timeouts**
   ```sh
   curl -s http://localhost:8080/metrics | grep agent_timeout_total
   tail -f logs/api.log | grep "agent timeout"
   ```
2. **Inspect OpenAI status** – check provider dashboard or run a direct test request with `curl`/`scripts/openai_smoke.sh`.
3. **Check breaker state** – ensure the circuit breaker runbook isn’t already engaged.

## Mitigation
- Reduce load or disable agent temporarily:
  ```sh
  export AGENT_API_KEY=""
  systemctl restart chessmate-api   # or equivalent deployment restart
  ```
  Queries will return heuristic results without GPT-5 reasoning.
- Increase timeout cautiously if upstream latency is known to be elevated:
  ```sh
  export AGENT_REQUEST_TIMEOUT_SECONDS=25
  systemctl restart chessmate-api
  ```
  _Only apply when the provider confirms high latency and the business impact of longer waits is acceptable._
- Tune retry strategy:
  - `OPENAI_RETRY_MAX_ATTEMPTS`
  - `OPENAI_RETRY_BASE_DELAY_MS`

## Post-Mortem Actions
1. Remove any temporary overrides after stability returns.
2. File an incident report (`docs/INCIDENTS/incident-template.md`) if customer-facing degradation occurred.
3. Consider enabling the agent cache (`AGENT_CACHE_REDIS_URL`) or adjusting cache capacity/TTL to reduce repeated calls.
4. Update `LOAD_TESTING.md` benchmarks if timeouts were caused by load tests or new traffic patterns.
