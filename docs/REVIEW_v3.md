# Chessmate Codebase Review v3.0
## Comprehensive Analysis & Improvement Roadmap

**Review Date**: 2025-10-10
**Baseline**: Post-Caqti migration (v0.6.0), vector upload implementation, metrics endpoint, sanitization
**Status**: Production-ready foundation with critical gaps remaining

---

## Executive Summary

### Recent Achievements (v0.5.x → v0.6.0)

**Major Infrastructure Upgrades:**
1. **Caqti Migration Complete** ✅
   - Replaced libpq shell wrapper with typed Caqti pool
   - Parameterized queries throughout (SQL injection risk eliminated)
   - Pool instrumentation via `/metrics` endpoint
   - Evidence: lib/storage/repo_postgres_caqti.ml:1-300, services/api/chessmate_api.ml:278-301

2. **Vector Upload Implemented** ✅
   - Worker now uploads embeddings to Qdrant with retry logic
   - Payload enrichment from Postgres metadata
   - 3-attempt exponential backoff for transient failures
   - Evidence: services/embedding_worker/embedding_worker.ml:142-192

3. **Secret Sanitization** ✅
   - Regex-based redaction of API keys, database URLs, Redis URIs
   - Applied to all error messages and logs
   - Test coverage in place
   - Evidence: lib/core/sanitizer.ml:1-25, test/test_sanitizer.ml

4. **Observability Foundation** ✅
   - `/metrics` endpoint exposing pool stats (capacity, in_use, waiting, wait_ratio)
   - Load testing script with oha/vegeta support and guidance in docs/TESTING.md
   - Integration tests for core workflows
   - Evidence: services/api/chessmate_api.ml:278-301, scripts/load_test.sh, docs/TESTING.md:1-125, test/test_integration.ml

### Critical Gaps Remaining

1. **No Rate Limiting** 🔴 (Blocker for public deployment)
2. **Qdrant Collection Initialization Missing** 🔴 (Clean deployment fails)
3. **Limited Prometheus Metrics** 🟡 (Only DB pool, no request/latency metrics)
4. **No Deep Health Checks** 🟡 (Doesn't verify Qdrant/Redis connectivity)
5. **Agent Evaluation Timeout Missing** 🟡 (Can block queries indefinitely)
6. **Query Result Pagination Missing** 🟡 (Unbounded result sets risk OOM)

### Effort Summary

| Priority | Tasks | Est. Hours |
|----------|-------|------------|
| **Critical** | 2 | 18-26 |
| **High** | 6 | 52-76 |
| **Medium** | 15 | 98-150 |
| **Low** | 8 | 48-74 |
| **Total** | **31** | **216-326** |

---

## Part 1: Critical Priority (18-26 hours)

### C1. API Rate Limiting [PRODUCTION BLOCKER]
**Impact**: Unprotected API vulnerable to abuse, quota exhaustion, Postgres connection starvation
**Current State**: No throttling middleware in services/api/chessmate_api.ml

**Required Implementation:**
```ocaml
(* lib/api/rate_limiter.ml - new module *)
type t = {
  bucket : (string, float ref * int ref) Hashtbl.t;  (* IP -> (last_refill, tokens) *)
  mutex : Stdlib.Mutex.t;
  tokens_per_minute : int;
  refill_interval : float;
}

let check t ~remote_addr =
  (* Token bucket algorithm with per-IP tracking *)
  (* Return Ok () or Error "Rate limit exceeded" *)
```

**Integration:**
- Add Opium middleware wrapping `query_handler`
- Return HTTP 429 with `Retry-After` header
- Config via `CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE` (default 60)
- Add `/metrics` counter: `api_rate_limited_total{ip}`

**Test Coverage:**
- Unit tests for token bucket logic
- Integration test verifying 429 response after threshold
- Load test confirming legitimate traffic unaffected

**Files to Create:**
- lib/api/rate_limiter.ml + .mli
- test/test_rate_limiter.ml

**Files to Modify:**
- services/api/chessmate_api.ml:351-357 (add middleware)
- docs/OPERATIONS.md (document tuning)
- docs/openapi.yaml (add 429 response)

**Effort**: 10-14 hours

---

### C2. Qdrant Collection Initialization
**Impact**: First deployment fails with "collection not found" error; manual `curl` required
**Current State**: Worker/API assume `positions` collection exists (lib/storage/repo_qdrant.ml:22)

**Required Implementation:**
```ocaml
(* lib/storage/repo_qdrant.ml - add function *)
let ensure_collection ~name ~vector_size ~distance =
  let check_url = Config.url (Printf.sprintf "/collections/%s" name) in
  match get_request check_url with
  | Ok _ -> Ok ()  (* Collection exists *)
  | Error _ ->
      (* Create with schema *)
      let payload = `Assoc [
        "vectors", `Assoc [
          "size", `Int vector_size;
          "distance", `String distance
        ];
        "payload_schema", `Assoc [
          "game_id", `String "integer";
          "fen", `String "keyword";
          "white", `String "keyword";
          "black", `String "keyword";
          "opening_slug", `String "keyword"
        ]
      ] in
      put_request (Config.url "/collections") payload
```

**Integration:**
- Call from API startup (after config load, before port binding)
- Call from worker startup (before work_loop)
- Add `QDRANT_COLLECTION_NAME` env var (default "positions")
- Add `QDRANT_VECTOR_SIZE` env var (default 1536 for text-embedding-3-small)

**Test Coverage:**
- Integration test creating collection on first run
- Test verifying idempotency (second call succeeds)
- Test with existing collection (no-op)

**Files to Modify:**
- lib/storage/repo_qdrant.ml (add ensure_collection, get_request, put_request helpers)
- services/api/chessmate_api.ml (call on startup)
- services/embedding_worker/embedding_worker.ml (call on startup)
- lib/storage/repo_qdrant.mli (expose ensure_collection)

**Effort**: 8-12 hours

---

## Part 2: High Priority (52-76 hours)

### H1. Prometheus Metrics Instrumentation
**Impact**: No visibility into request latency, error rates, queue depth, cache hit rates
**Current State**: Only `/metrics` endpoint with DB pool gauges (4 metrics total)

**Required Metrics:**

```ocaml
(* Core API metrics *)
chessmate_http_requests_total{method, path, status} - Counter
chessmate_http_request_duration_seconds{method, path} - Histogram (p50, p95, p99)
chessmate_http_requests_in_flight{method, path} - Gauge

(* Query pipeline metrics *)
chessmate_query_vector_hits_total - Counter
chessmate_query_metadata_hits_total - Counter
chessmate_query_keywords_matched_total - Histogram

(* Agent metrics *)
chessmate_agent_evaluations_total{cached} - Counter
chessmate_agent_evaluation_duration_seconds - Histogram
chessmate_agent_token_usage_total{type} - Counter (input, output, reasoning)
chessmate_agent_cost_usd_total - Counter

(* Worker metrics *)
chessmate_worker_jobs_claimed_total - Counter
chessmate_worker_jobs_completed_total - Counter
chessmate_worker_jobs_failed_total - Counter
chessmate_worker_embedding_duration_seconds - Histogram
chessmate_worker_qdrant_upsert_duration_seconds - Histogram

(* Infrastructure metrics *)
chessmate_db_pool_capacity - Gauge (existing)
chessmate_db_pool_in_use - Gauge (existing)
chessmate_db_pool_waiting - Gauge (existing)
chessmate_db_pool_wait_ratio - Gauge (existing)
chessmate_redis_operations_total{operation} - Counter
chessmate_qdrant_requests_total{operation, status} - Counter
```

**Implementation:**
```ocaml
(* lib/observability/metrics.ml - new module *)
module Prometheus = Prometheus
module Counter = Prometheus.Counter
module Histogram = Prometheus.Histogram
module Gauge = Prometheus.Gauge

let namespace = "chessmate"

let http_requests_total =
  Counter.v_labels ~help:"Total HTTP requests" ~namespace
    ~label_names:["method"; "path"; "status"]

let http_duration =
  Histogram.v_labels ~help:"HTTP request latency" ~namespace
    ~label_names:["method"; "path"]
    ~buckets:[0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 2.0; 5.0]

(* ... 20+ more metric definitions ... *)
```

**Integration:**
- Add `prometheus` and `prometheus-app` to dune-project dependencies
- Wrap all HTTP handlers with duration tracking
- Instrument Hybrid_executor, Agent_evaluator, Repo_postgres, Repo_qdrant
- Update `/metrics` to return Prometheus text format
- Add Grafana dashboard JSON to docs/dashboards/chessmate.json

**Test Coverage:**
- Unit tests verifying metric registration
- Integration test confirming `/metrics` exposes all expected metrics
- Load test capturing baseline p95 latencies

**Files to Create:**
- lib/observability/metrics.ml + .mli
- lib/observability/dune
- docs/dashboards/chessmate.json (Grafana)
- docs/MONITORING.md (scrape config, alerting rules)

**Files to Modify:**
- dune-project (add prometheus deps)
- services/api/chessmate_api.ml (instrument handlers)
- lib/query/hybrid_executor.ml (track query metrics)
- lib/query/agent_evaluator.ml (track agent metrics)
- services/embedding_worker/embedding_worker.ml (track worker metrics)

**Effort**: 16-22 hours

---

### H2. Deep Health Checks
**Impact**: Orchestrators (k8s, Docker Swarm) can't distinguish "listening" from "ready"
**Current State**: `/health` returns `ok` without dependency verification (services/api/chessmate_api.ml:276)

**Required Implementation:**
```ocaml
let health_deep _req =
  let checks = [
    ("postgres", check_postgres);
    ("qdrant", check_qdrant);
    ("redis", check_redis_if_configured);
  ] in
  let results = List.map checks ~f:(fun (name, check) ->
    match check () with
    | Ok () -> (name, `String "ok")
    | Error err -> (name, `String (Sanitizer.sanitize_error err))
  ) in
  let all_ok = List.for_all results ~f:(function _, `String "ok" -> true | _ -> false) in
  let status = if all_ok then `OK else `Service_unavailable in
  respond_json ~status (`Assoc results)

let check_postgres () =
  match Lazy.force postgres_repo with
  | Error err -> Error err
  | Ok repo -> Repo_postgres.Private.health_check repo

let check_qdrant () =
  Repo_qdrant.health_check ()  (* GET /healthz *)

let check_redis_if_configured () =
  match Lazy.force agent_cache with
  | None -> Or_error.return ()  (* Not configured, skip *)
  | Some cache -> Agent_cache.health_check cache  (* PING *)
```

**Integration:**
- Add `GET /health/live` (current behavior, always 200 OK)
- Add `GET /health/ready` (deep checks, returns 503 if any dependency down)
- Update k8s/Docker Compose to use separate liveness/readiness probes
- Add optional `?verbose=true` query param to include latency/version info

**Test Coverage:**
- Integration test with healthy dependencies (returns 200)
- Integration test with Qdrant down (returns 503 with details)
- Integration test with Postgres down (returns 503)

**Files to Modify:**
- services/api/chessmate_api.ml (add health_deep, routes)
- lib/storage/repo_postgres_caqti.ml (add health_check to Private module)
- lib/storage/repo_qdrant.ml (add health_check function)
- lib/query/agent_cache.ml (add health_check)
- docs/OPERATIONS.md (document probe endpoints)
- docs/openapi.yaml (add /health/ready endpoint)

**Effort**: 6-8 hours

---

### H3. Agent Evaluation Timeout
**Impact**: Single slow GPT-5 response (30s+) blocks query indefinitely; no fallback
**Current State**: No timeout in lib/agents/agents_gpt5_client.ml:generate

**Required Implementation:**
```ocaml
(* lib/agents/agents_gpt5_client.ml *)
type t = {
  (* existing fields *)
  timeout : float option;  (* Default 30.0 seconds *)
}

let create ~api_key ~endpoint ?timeout () =
  let timeout = Option.value timeout ~default:30.0 in
  { (* ... *); timeout = Some timeout }

let generate_with_timeout t ~prompt =
  match t.timeout with
  | None -> generate_internal t ~prompt
  | Some timeout_sec ->
      let open Lwt.Syntax in
      let timeout_promise =
        let* () = Lwt_unix.sleep timeout_sec in
        Lwt.return (Error (Error.of_string "Agent evaluation timed out"))
      in
      let call_promise = Lwt.return (generate_internal t ~prompt) in
      Lwt_main.run (Lwt.pick [ call_promise; timeout_promise ])
```

**Integration:**
- Add `AGENT_TIMEOUT_SECONDS` env var (default 30)
- Parse in lib/core/config.ml
- On timeout, return `None` for agent_score/explanation
- Add warning to execution: "Agent evaluation timed out after 30s"
- Increment metrics: `chessmate_agent_timeouts_total`

**Test Coverage:**
- Unit test mocking slow agent (returns after 35s, verify timeout at 30s)
- Integration test confirming query completes with timeout warning
- Verify non-timeout calls unaffected

**Files to Modify:**
- lib/agents/agents_gpt5_client.ml (add timeout parameter)
- lib/agents/agents_gpt5_client.mli (expose timeout in create)
- lib/query/agent_evaluator.ml (handle timeout error gracefully)
- lib/core/config.ml (parse AGENT_TIMEOUT_SECONDS)
- docs/DEVELOPER.md (document config variable)

**Effort**: 4-6 hours

---

### H4. Embedding Job Retry Policy
**Impact**: Transient OpenAI 429s mark jobs as permanently failed; manual re-ingest required
**Current State**: Worker marks failed on first error (services/embedding_worker/embedding_worker.ml:146)

**Schema Change Required:**
```sql
-- migrations/0008_add_job_retry_count.sql
ALTER TABLE embedding_jobs ADD COLUMN retry_count INTEGER DEFAULT 0;
ALTER TABLE embedding_jobs ADD COLUMN next_retry_after TIMESTAMPTZ;
```

**Worker Logic:**
```ocaml
let process_job repo embedding_client ~label stats (job : Embedding_job.t) =
  match Embedding_client.embed_fens embedding_client [ job.fen ] with
  | Error err when should_retry err ->
      let retry_count = job.retry_count + 1 in
      if retry_count >= 3 then
        mark_job_failed repo ~job_id:job.id ~error:(sanitize err)
      else
        let delay_seconds = Int.pow 2 retry_count * 60 in  (* 1min, 2min, 4min *)
        mark_job_retry repo ~job_id:job.id ~retry_count ~delay_seconds
  | Error err ->
      mark_job_failed repo ~job_id:job.id ~error:(sanitize err)
  | Ok vectors -> (* existing success path *)
```

**Claim Logic Update:**
```ocaml
(* Only claim jobs with retry_count < 3 AND next_retry_after < NOW() *)
SELECT * FROM embedding_jobs
WHERE status = 'pending'
  AND retry_count < 3
  AND (next_retry_after IS NULL OR next_retry_after <= NOW())
ORDER BY created_at ASC
LIMIT ?
FOR UPDATE SKIP LOCKED
```

**Operational Tooling:**
```bash
# scripts/retry_failed_jobs.sh - reset retry_count for manual re-attempts
UPDATE embedding_jobs
SET status = 'pending', retry_count = 0, next_retry_after = NULL
WHERE status = 'failed' AND error LIKE '%rate_limit%'
LIMIT 1000;
```

**Test Coverage:**
- Integration test simulating transient failure (verify retry scheduled)
- Test verifying job fails after 3 attempts
- Test confirming next_retry_after honored in claim query

**Effort**: 10-14 hours

---

### H5. Query Result Pagination
**Impact**: Large result sets (1000+ games) cause JSON serialization slowdown, potential OOM
**Current State**: No limit enforcement; plan.limit could be arbitrarily high

**Implementation:**
```ocaml
(* lib/query/query_intent.ml - enforce max *)
let default_limit = 50
let max_limit = 200

let analyse input =
  let limit = extract_limit input.text in
  let clamped_limit = Int.min (Int.max 1 limit) max_limit in
  { (* ... *); limit = clamped_limit }

(* services/api/chessmate_api.ml - add offset param *)
let extract_pagination req =
  let uri = Request.uri req in
  let offset = Uri.get_query_param uri "offset"
               |> Option.bind ~f:Int.of_string_opt
               |> Option.value ~default:0 in
  let limit = Uri.get_query_param uri "limit"
              |> Option.bind ~f:Int.of_string_opt
              |> Option.value ~default:50
              |> Int.min max_limit in
  (offset, limit)
```

**Response Schema:**
```json
{
  "results": [ /* ... */ ],
  "pagination": {
    "offset": 0,
    "limit": 50,
    "total": 237,
    "has_more": true
  }
}
```

**SQL Update:**
```sql
SELECT ... FROM games
WHERE ...
ORDER BY played_on DESC
LIMIT ? OFFSET ?
```

**Test Coverage:**
- Integration test verifying limit clamped to 200
- Test pagination with offset=50, limit=50 (returns games 51-100)
- Test has_more flag accuracy

**Files to Modify:**
- lib/query/query_intent.ml (clamp limit)
- services/api/chessmate_api.ml (parse offset, return pagination metadata)
- lib/storage/repo_postgres_caqti.ml (add offset to search_games)
- docs/openapi.yaml (add offset/limit params, pagination response)

**Effort**: 6-8 hours

---

### H6. Redis Connection Pooling
**Impact**: Single Redis connection under concurrent agent requests causes serialization
**Current State**: Agent_cache likely uses single synchronous connection

**Implementation:**
```ocaml
(* lib/query/agent_cache.ml - migrate to Redis_lwt *)
type redis_pool = {
  pool : (Redis_lwt.connection, exn) Lwt_pool.t;
  capacity : int;
}

let create_redis ?pool_size ~url =
  let pool_size = Option.value pool_size ~default:10 in
  let uri = Uri.of_string url in
  let create_conn () =
    let host = Uri.host_with_default uri in
    let port = Option.value (Uri.port uri) ~default:6379 in
    Redis_lwt.Client.connect ~host ~port ()
  in
  let pool = Lwt_pool.create pool_size create_conn in
  { pool; capacity = pool_size }

let get redis_pool key =
  Lwt_pool.use redis_pool.pool (fun conn ->
    Redis_lwt.Client.get conn key
  ) |> Lwt_main.run
```

**Integration:**
- Add `AGENT_CACHE_REDIS_POOL_SIZE` env var (default 10)
- Add pool metrics to `/metrics`: `redis_pool_in_use`, `redis_pool_waiting`
- Update agent cache docs with pooling guidance

**Test Coverage:**
- Integration test with 20 concurrent cache gets (verify no serialization)
- Test pool exhaustion behavior (21st request waits)

**Files to Modify:**
- lib/query/agent_cache.ml (migrate to Redis_lwt + Lwt_pool)
- lib/core/config.ml (add pool_size parsing)
- docs/OPERATIONS.md (document tuning)

**Effort**: 8-12 hours

---

## Part 3: Medium Priority (98-150 hours)

### M1. Testing Guide Enhancements
**Impact**: New contributors can run unit and integration suites, but advanced scenarios (selective test execution, load testing expectations, troubleshooting matrix) still require tribal knowledge.
**Current State**: `docs/TESTING.md` provides a solid quick-start and now documents the load test harness; expand it to cover selective Alcotest patterns, Qdrant/OpenAI stubbing, and expected `/metrics` signals (e.g., `db_pool_wait_ratio` thresholds under load).

**Required Additions:**
- Document how to run single Alcotest suites (`dune exec test/test_main.exe -- test integration --only ingestion`).
- Add section on mocking Qdrant/OpenAI via `Repo_qdrant.with_test_hooks` / embedding client stubs.
- Include troubleshooting table mapping common failures (`db_pool_wait_ratio > 0.5`, `agent timeout`, `docker compose ps`).
- Cross-link to load testing checklist emphasizing capture of pool stats before/after.

**Effort**: 2-3 hours

---

### M2. FEN Normalization Audit
**Impact**: Equivalent positions may generate distinct vectors ("KQkq" vs "Kk" after h1 rook moves)
**Current State**: lib/chess/fen.ml:55 normalizes castling, but edge cases unclear

**Required Work:**
- Audit normalize_castling against FIDE standard
- Add normalization for:
  - Castling rights order (always KQkq, not QKqk)
  - En passant square (only if legal capture exists)
  - Halfmove clock after irreversible moves
- Add test cases with equivalent FENs (verify same hash after normalization)
- Apply normalization before hashing in embedding_worker.ml:157

**Test Cases:**
```ocaml
let test_castling_normalization () =
  let fen1 = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1" in
  let fen2 = "r3k2r/8/8/8/8/8/8/R3K2R w QKqk - 0 1" in  (* Wrong order *)
  check string "normalized" (normalize fen1) (normalize fen2)

let test_en_passant_validation () =
  (* e4 move doesn't create en passant if no enemy pawn on d4/f4 *)
  let invalid = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1" in
  let valid = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1" in
  check string "ep removed" valid (normalize invalid)
```

**Effort**: 6-8 hours

---

### M3. Query Syntax Documentation
**Impact**: Users don't know how to filter by rating, ECO, result; trial-and-error UX
**Current State**: Query parsing logic in lib/query/query_intent.ml undocumented

**Required Content (docs/QUERY_SYNTAX.md):**
```markdown
# Query Syntax Guide

## Basic Filters

### Opening Filters
- "King's Indian Defense" → opening_slug match
- "eco:E60-E99" → ECO range filter
- "Sicilian Najdorf" → opening name fuzzy match

### Player Filters
- "Kasparov" → white OR black match
- "white:Carlsen" → white player only
- "black:Nakamura" → black player only

### Rating Filters
- "2700+" → white_min OR black_min >= 2700
- "white 2800+" → white_rating >= 2800
- "rating delta < 50" → |white_rating - black_rating| <= 50

### Result Filters
- "white wins" → result = "1-0"
- "draw" → result = "1/2-1/2"
- "black wins" → result = "0-1"

### Event Filters
- "Candidates 2024" → event ILIKE '%candidates%2024%'

### Limit Control
- "top 10 games" → limit = 10
- Default: 50, Maximum: 200

## Combining Filters
"Find King's Indian games where white is 2700+ and black within 100 points, top 20"
→ Filters: [opening_slug="kings_indian_defense"], rating: {white_min=2700, max_delta=100}, limit: 20

## Examples
- "Najdorf sacrifices by Kasparov with white wins"
- "French Defense draws between 2500+ players"
- "Ruy Lopez games from Candidates tournaments"
```

**Integration:**
- Link from README.md
- Link from OpenAPI spec description
- Add to DEVELOPER.md under "CLI Usage"

**Effort**: 4-6 hours

---

### M4. Agent Evaluation Cost Tracking
**Impact**: No budget visibility; agent calls could silently burn through OpenAI quota
**Current State**: Token usage logged but not costed (lib/query/agent_telemetry.ml)

**Implementation:**
```ocaml
(* lib/core/config.ml *)
type agent_pricing = {
  input_per_1k : float;   (* Default $0.002 for GPT-4 *)
  output_per_1k : float;  (* Default $0.006 *)
  reasoning_per_1k : float;  (* Default $0.001 *)
}

let load_agent_pricing () =
  {
    input_per_1k = parse_env_float "AGENT_COST_INPUT_PER_1K" ~default:0.002;
    output_per_1k = parse_env_float "AGENT_COST_OUTPUT_PER_1K" ~default:0.006;
    reasoning_per_1k = parse_env_float "AGENT_COST_REASONING_PER_1K" ~default:0.001;
  }

(* lib/query/agent_telemetry.ml *)
let calculate_cost ~usage ~pricing =
  let input_cost = Float.of_int usage.input_tokens /. 1000. *. pricing.input_per_1k in
  let output_cost = Float.of_int usage.output_tokens /. 1000. *. pricing.output_per_1k in
  let reasoning_cost = Float.of_int usage.reasoning_tokens /. 1000. *. pricing.reasoning_per_1k in
  input_cost +. output_cost +. reasoning_cost

let log telemetry =
  (* existing logging + *)
  eprintf "[agent-telemetry] estimated_cost_usd=%.4f\n%!" telemetry.estimated_cost
```

**Metrics:**
```ocaml
chessmate_agent_cost_usd_total - Counter (cumulative spend)
chessmate_agent_cost_per_evaluation_usd - Histogram (cost distribution)
```

**Response JSON:**
```json
{
  "agent_usage": {
    "input_tokens": 1234,
    "output_tokens": 567,
    "reasoning_tokens": 890,
    "estimated_cost_usd": 0.0234
  }
}
```

**Test Coverage:**
- Unit test verifying cost calculation
- Integration test confirming cost in response JSON

**Effort**: 4-6 hours

---

### M5. Worker Health Metrics Endpoint
**Impact**: No observability into worker process health; blind to stalls/crashes
**Current State**: Workers log to stderr only

**Implementation:**
```ocaml
(* services/embedding_worker/embedding_worker.ml *)
let start_metrics_server port stats =
  let handler _req =
    let body = Printf.sprintf
      "worker_jobs_claimed_total %d\n\
       worker_jobs_completed_total %d\n\
       worker_jobs_failed_total %d\n\
       worker_uptime_seconds %.0f\n"
      stats.processed
      (stats.processed - stats.failed)
      stats.failed
      (Unix.gettimeofday () -. start_time)
    in
    App.respond' (`String body)
  in
  let app = App.empty |> App.get "/metrics" handler in
  Lwt_main.run (Opium.App.run_command' app ~port)

(* Main *)
match Stdlib.Sys.getenv_opt "CHESSMATE_WORKER_METRICS_PORT" with
| Some port_str when Int.of_string_opt port_str |> Option.is_some ->
    let port = Int.of_string_opt port_str |> Option.value_exn in
    Thread.create (fun () -> start_metrics_server port stats) () |> ignore
| _ -> ()
```

**Metrics Exposed:**
- worker_jobs_claimed_total
- worker_jobs_completed_total
- worker_jobs_failed_total
- worker_embedding_duration_seconds (requires instrumentation)
- worker_qdrant_upsert_duration_seconds
- worker_uptime_seconds

**Test Coverage:**
- Integration test starting worker with metrics port
- Verify GET /metrics returns Prometheus format

**Effort**: 8-12 hours

---

### M6. PGN Export Endpoint
**Impact**: Users can't retrieve full PGN for game analysis; manual database query required
**Current State**: No `/games/{id}/pgn` endpoint

**Implementation:**
```ocaml
(* services/api/chessmate_api.ml *)
let pgn_handler req =
  let game_id_str = Dream.param req "id" in
  match Int.of_string_opt game_id_str with
  | None -> respond_json ~status:`Bad_request (`Assoc ["error", `String "Invalid game ID"])
  | Some game_id -> (
      match Lazy.force postgres_repo with
      | Error err -> respond_json ~status:`Internal_server_error (...)
      | Ok repo -> (
          match Repo_postgres.fetch_games_with_pgn repo ~ids:[game_id] with
          | Error err -> respond_json ~status:`Internal_server_error (...)
          | Ok [] -> respond_json ~status:`Not_found (`Assoc ["error", `String "Game not found"])
          | Ok (game :: _) ->
              let headers = Cohttp.Header.init_with "Content-Type" "application/x-chess-pgn" in
              App.respond' ~headers (`String game.pgn)))

(* Routes *)
|> App.get "/games/:id/pgn" pgn_handler
```

**Rate Limiting:**
- Separate bucket from `/query` (higher limit, e.g., 120/min)
- Cache PGN responses with 1-hour TTL

**OpenAPI Spec:**
```yaml
/games/{id}/pgn:
  get:
    summary: Retrieve PGN for a specific game
    parameters:
      - name: id
        in: path
        required: true
        schema: {type: integer}
    responses:
      '200':
        description: PGN content
        content:
          application/x-chess-pgn:
            schema: {type: string}
      '404': {description: Game not found}
```

**Test Coverage:**
- Integration test ingesting game, retrieving PGN
- Test with invalid game ID (returns 404)

**Effort**: 4-6 hours

---

### M7. Bulk Export Tool
**Impact**: No backup/migration tooling; manual pg_dump + Qdrant snapshots required
**Current State**: No export CLI command

**Implementation:**
```ocaml
(* lib/cli/export_command.ml *)
let run ~format ~output =
  match Repo_postgres.create database_url with
  | Error err -> Error err
  | Ok repo ->
      let out_channel = Stdio.Out_channel.create output in
      match format with
      | `Json ->
          (* Stream games as JSONL *)
          Repo_postgres.stream_all_games repo ~f:(fun game ->
            let json = game_to_json game in
            Stdio.Out_channel.fprintf out_channel "%s\n" (Yojson.Safe.to_string json)
          )
      | `Pgn ->
          (* Stream games as concatenated PGN *)
          Repo_postgres.stream_all_games repo ~f:(fun game ->
            Stdio.Out_channel.fprintf out_channel "%s\n\n" game.pgn
          )
```

**CLI:**
```bash
chessmate export --format json --output games.jsonl
chessmate export --format pgn --output backup.pgn
chessmate export-vectors --output vectors.npy  # Qdrant snapshot
```

**Test Coverage:**
- Integration test exporting 10 games to JSONL
- Verify PGN format has correct separators

**Effort**: 8-12 hours

---

### M8. Docker Multi-Stage Build
**Impact**: No production-ready container images; manual `dune exec` on host
**Current State**: No Dockerfile

**Implementation:**
```dockerfile
# Dockerfile.api
FROM ocaml/opam:alpine-5.1 AS builder
WORKDIR /src
COPY . .
RUN opam install . --deps-only && \
    eval $(opam env) && \
    dune build services/api/chessmate_api.exe

FROM alpine:3.19
RUN apk add --no-cache libpq
COPY --from=builder /src/_build/default/services/api/chessmate_api.exe /usr/local/bin/chessmate-api
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/chessmate-api"]

# Dockerfile.worker (similar structure)
```

**Build Tooling:**
```makefile
# Makefile
docker-build-api:
	docker build -f Dockerfile.api -t chessmate-api:latest .

docker-build-worker:
	docker build -f Dockerfile.worker -t chessmate-worker:latest .

docker-push:
	docker tag chessmate-api:latest ghcr.io/hendrikreh/chessmate-api:latest
	docker push ghcr.io/hendrikreh/chessmate-api:latest
```

**Test Coverage:**
- CI job building Docker images on PR
- Integration test running containerized API

**Effort**: 6-8 hours

---

### M9. OpenAPI Request Validation
**Impact**: Schema drift between spec and implementation; inconsistent error responses
**Current State**: Manual validation in handlers

**Implementation:**
```ocaml
(* lib/api/openapi_validator.ml - new module using openapi-ocaml *)
type t = {
  spec : Openapi.Document.t;
  operations : (string * string, Openapi.Operation.t) Hashtbl.t;  (* (method, path) -> operation *)
}

let load spec_path =
  let json = Yojson.Safe.from_file spec_path in
  Openapi.Document.of_yojson json

let validate_request t ~method_ ~path ~query ~body =
  match Hashtbl.find_opt t.operations (method_, path) with
  | None -> Ok ()  (* No spec defined, allow *)
  | Some operation ->
      (* Validate query params against operation.parameters *)
      (* Validate body against operation.requestBody.schema *)
      (* Return Error with details on mismatch *)
```

**Integration:**
- Load spec on API startup
- Add middleware validating requests
- Return 400 with detailed error on validation failure
- In dev mode, validate responses (log warnings on mismatch)

**Test Coverage:**
- Integration test with missing required param (returns 400)
- Test with invalid JSON schema (returns 400)
- Test valid request (passes through)

**Effort**: 10-14 hours

---

### M10-M15. Additional Medium Priority Tasks

**M10. Logging Framework Migration** (4-8h)
- Replace ad-hoc Stdio.eprintf with structured `Logs` library
- Add JSON formatter for production
- Configure log level via CHESSMATE_LOG_LEVEL

**M11. Admin CLI Commands** (8-12h)
- `chessmate admin reindex-vectors` (rebuild Qdrant from Postgres)
- `chessmate admin flush-cache --pattern 'chessmate:agent:*'`
- `chessmate admin vacuum-embeddings` (delete orphaned jobs)

**M12. Load Testing Suite** (6-10h)
- Add test/load/ directory with locust/wrk scripts
- Test scenarios: 100 concurrent /query, 1000 games/sec ingest
- Document baseline performance in docs/PERFORMANCE.md

**M13. Error Code Standardization** (2-4h)
- Define error schema: `{"error": {"code": "INVALID_QUERY", "message": "..."}}`
- Update all handlers to use respond_error helper
- Add error code registry in docs

**M14. Worker Auto-Scaling** (12-16h)
- Add --auto-scale flag to embedding worker
- Query queue depth every 60s, spawn/join threads dynamically
- Scale: <1k=1 worker, 1k-10k=4, 10k-50k=8, >50k=16 (cap)

**M15. Opening Catalogue Tests** (4-6h)
- Create test/test_openings.ml
- Test ECO code lookup, case-insensitive matching
- Smoke test verifying all 500 entries parse

**Total M1-M15 Effort**: 98-150 hours

---

## Part 4: Low Priority (48-74 hours)

### L1. Security Headers Middleware
**Impact**: Missing defense-in-depth headers; vulnerability to clickjacking, MIME sniffing
**Current State**: No headers set in respond_json/respond_plain_text

**Implementation:**
```ocaml
let security_headers_middleware handler req =
  let open Lwt.Syntax in
  let* response = handler req in
  let headers = Cohttp.Response.headers response in
  let headers =
    headers
    |> Cohttp.Header.add_unless_exists "X-Content-Type-Options" "nosniff"
    |> Cohttp.Header.add_unless_exists "X-Frame-Options" "DENY"
    |> Cohttp.Header.add_unless_exists "X-XSS-Protection" "1; mode=block"
    |> Cohttp.Header.add_unless_exists "Content-Security-Policy" "default-src 'self'"
  in
  Lwt.return (Cohttp.Response.make ~headers ())
```

**Effort**: 2-4 hours

---

### L2. Vector Search Fallback Documentation
**Impact**: Operators unclear how API behaves when Qdrant unavailable
**Current State**: Fallback implemented but undocumented

**Required Docs (OPERATIONS.md section):**
```markdown
## Degraded Mode: Vector Search Unavailable

When Qdrant is unreachable or returns errors, the API automatically falls back to metadata-only search:

- `/query` requests complete successfully
- `vector_score` fields set to 0.0
- Warning added to response: `["Vector search unavailable, using metadata only"]`
- Postgres filters still applied (opening, rating, result, etc.)

### Recovery Steps
1. Check Qdrant health: `curl http://localhost:6333/healthz`
2. Inspect API logs for `[qdrant]` errors
3. Restart Qdrant: `docker compose restart qdrant`
4. Verify recovery: `curl http://localhost:8080/health/ready` (should return 200)

### Monitoring
- Alert on: `chessmate_qdrant_requests_total{status="error"}` sustained > 5/min
- Dashboard panel: Qdrant availability % (200 responses / total requests)
```

**Effort**: 2-3 hours

---

### L3. Config Validation Tests Expansion
**Impact**: Edge cases in config parsing may silently fail or use wrong defaults
**Current State**: Basic tests in test/test_config.ml

**Additional Test Cases:**
```ocaml
let test_invalid_pool_size () =
  (* CHESSMATE_DB_POOL_SIZE=abc should use default 10 *)
  Stdlib.Sys.putenv "CHESSMATE_DB_POOL_SIZE" "abc";
  let config = Config.Api.load () |> Or_error.ok_exn in
  check int "default pool size" 10 config.db_pool_size

let test_negative_pool_size () =
  Stdlib.Sys.putenv "CHESSMATE_DB_POOL_SIZE" "-5";
  let config = Config.Api.load () |> Or_error.ok_exn in
  check int "default pool size" 10 config.db_pool_size

let test_missing_required_var () =
  Stdlib.Sys.unsetenv "DATABASE_URL";
  match Config.Api.load () with
  | Error err ->
      check bool "mentions DATABASE_URL"
        true
        (String.is_substring (Error.to_string_hum err) ~substring:"DATABASE_URL")
  | Ok _ -> fail "should have failed with missing DATABASE_URL"
```

**Effort**: 3-4 hours

---

### L4. Qdrant Payload Schema Validation
**Impact**: Worker may upload payloads incompatible with Qdrant collection schema
**Current State**: No schema enforcement in repo_qdrant.ml

**Implementation:**
```ocaml
(* lib/storage/repo_qdrant.ml *)
type payload_schema = {
  game_id : [`Integer];
  fen : [`Keyword];
  white : [`Keyword];
  black : [`Keyword];
  opening_slug : [`Keyword];
  vector_id : [`Keyword];
}

let validate_payload (json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  try
    let _ = json |> member "game_id" |> to_int in
    let _ = json |> member "fen" |> to_string in
    let _ = json |> member "white" |> to_string in
    let _ = json |> member "black" |> to_string in
    Ok ()
  with Type_error (msg, _) ->
    Or_error.errorf "Payload schema mismatch: %s" msg
```

**Integration:**
- Call validate_payload before upsert_points
- Return error to worker (job marked failed with schema error)

**Test Coverage:**
- Unit test with missing required field (returns error)
- Test with wrong type (e.g., game_id as string)

**Effort**: 4-6 hours

---

### L5-L8. Additional Low Priority Tasks

**L5. Agent Cache TTL Configuration** (2-3h)
- Validate AGENT_CACHE_TTL_SECONDS parsing
- Document TTL strategy (shorter for dev, longer for prod)
- Add test verifying cache expiration

**L6. Metrics Cardinality Audit** (4-6h)
- Review all label sets for high-cardinality risks
- Document max cardinality per metric in MONITORING.md
- Add guards preventing unbounded label values (e.g., user_id)

**L7. OpenAPI Examples Expansion** (3-4h)
- Add 10+ request/response examples to docs/openapi.yaml
- Cover edge cases: pagination, filters, agent evaluation
- Link examples from QUERY_SYNTAX.md

**L8. CI Performance Regression Tests** (6-8h)
- Add CI job running load_test.sh on PR
- Fail if p95 latency regresses >20% vs main
- Cache baseline metrics in artifacts

**Total L1-L8 Effort**: 48-74 hours

---

## Part 5: Code Quality & Architecture Observations

### Strengths

1. **Type Safety** ✅
   - Comprehensive `.mli` interfaces (31 files)
   - No use of `Obj.magic` or unsafe casts found
   - Or_error.t consistently used for fallible operations

2. **Error Handling** ✅
   - Sanitization applied to all error messages (lib/core/sanitizer.ml)
   - Pattern matching preferred over exceptions
   - Retry logic with exponential backoff (lib/core/retry.ml)

3. **Test Coverage** ✅
   - 14 test suites covering parsing, FEN, config, retry, sanitization
   - Integration tests with database lifecycle management
   - Test hooks for Qdrant/OpenAI stubbing (repo_qdrant.ml:42-56)

4. **Documentation** ✅
   - 10 markdown docs covering architecture, operations, development
   - OpenAPI spec with examples
   - Release notes tracking changes

5. **Operational Tooling** ✅
   - Load testing script (scripts/load_test.sh)
   - Metrics script (scripts/embedding_metrics.sh)
   - Migration framework (scripts/migrate.sh)

### Areas for Improvement

1. **Missing Interface Files**
   - lib/storage/ingestion_queue.ml has no .mli (exposes all internals)
   - lib/query/result_formatter.ml has .mli but minimal type hiding
   - **Recommendation**: Add .mli for all public modules, hide Private submodules

2. **Inconsistent Error Contexts**
   - Some functions use `Or_error.tag ~tag:"context"` (good)
   - Others return `Or_error.error_string "raw message"` (less actionable)
   - **Recommendation**: Standardize on `Or_error.errorf "Component: %s" detail`

3. **Hard-Coded Constants**
   - lib/storage/repo_qdrant.ml:22 hard-codes collection name "positions"
   - services/embedding_worker/embedding_worker.ml:103 hard-codes Qdrant retry config
   - **Recommendation**: Move to Config module with env var overrides

4. **Limited Concurrency Primitives**
   - Heavy use of Stdlib.Mutex (repo_postgres_caqti.ml:38)
   - No use of Lwt.Mutex or concurrent data structures
   - **Recommendation**: Audit mutex contention under load, consider lock-free alternatives

5. **No Telemetry Sampling**
   - All agent calls logged (lib/query/agent_telemetry.ml)
   - High-traffic deployments may overwhelm logs
   - **Recommendation**: Add AGENT_TELEMETRY_SAMPLE_RATE (default 1.0 = 100%)

6. **Qdrant HTTP Client**
   - Direct Cohttp_lwt_unix.Client calls (repo_qdrant.ml:66-68)
   - No connection pooling or timeout configuration
   - **Recommendation**: Abstract behind Qdrant_client module with configurable timeout

### Architecture Observations

1. **Layering** ✅
   - Clean separation: Chess (parsing) → Storage (persistence) → Query (pipeline) → Services (HTTP)
   - No circular dependencies detected

2. **Dependency Injection** ✅
   - Functions accept ~fetch_games, ~fetch_vector_hits parameters
   - Enables testing with mocks (test/test_integration.ml:98-112)

3. **Configuration Strategy** 🟡
   - Config.Api.load() returns single validated record
   - But config spread across 20+ env vars with inconsistent naming
   - **Recommendation**: Consider config file (TOML/YAML) for structured settings, env vars as overrides

4. **State Management** ✅
   - Stateless HTTP handlers (no global mutable state)
   - Connection pools encapsulated in opaque types
   - Worker exit_condition properly synchronized with mutex

5. **Scalability Concerns** 🟡
   - Single Postgres/Qdrant instance (no read replicas)
   - No horizontal scaling story for API (assumes load balancer upstream)
   - **Recommendation**: Document multi-instance deployment in OPERATIONS.md

---

## Part 6: Documentation Gaps & Improvements

### Critical Documentation Missing

1. **API Authentication/Authorization**
   - No mention of how to secure /query endpoint
   - No discussion of API keys, mTLS, or OAuth
   - **Required**: Add SECURITY.md with authentication guidance

2. **Disaster Recovery**
   - OPERATIONS.md mentions backups but no restore procedures
   - No RTO/RPO guidance
   - **Required**: Add DISASTER_RECOVERY.md with runbooks

3. **Performance Tuning**
   - OPERATIONS.md suggests tuning but no methodology
   - No baseline metrics or targets documented
   - **Required**: Add PERFORMANCE.md with benchmarks, tuning matrix

### Documentation Accuracy Issues

1. **DEVELOPER.md:14** 🐛
   - Says "services now use Caqti under the hood" (correct)
   - But line 65 says "use libpq under the hood" (outdated)
   - **Fix**: Global search/replace "libpq" → "Caqti" in docs

2. **OPERATIONS.md:44** 🐛
   - Documents `/metrics` as "database pool only"
   - Needs update after Prometheus instrumentation (Task H1)
   - **Fix**: Defer update until metrics task complete

3. **RELEASE_NOTES.md:6-8** ✅
   - Accurately documents Caqti migration
   - Mentions postgresql library removed (correct per dune-project:24-33)

### Missing Operational Guides

1. **Multi-Region Deployment**
   - No guidance on running API in multiple regions
   - Qdrant replication strategy undocumented
   - **Required**: Add docs/deployment/MULTI_REGION.md

2. **Capacity Planning**
   - No guidance on sizing Postgres/Qdrant for X games
   - No memory/CPU requirements documented
   - **Required**: Add CAPACITY_PLANNING.md with sizing calculator

3. **Incident Runbooks**
   - TROUBLESHOOTING.md has diagnostics but no incident response
   - No playbooks for "API down", "Qdrant degraded", "Worker stalled"
   - **Required**: Add docs/runbooks/ directory with scenario-specific guides

---

## Part 7: Prioritized Recommendations

### Immediate Actions (Next Sprint)

1. **C1: API Rate Limiting** (10-14h)
   - Blocks public deployment
   - Prevents quota abuse
   - **Owner**: Backend lead

2. **C2: Qdrant Collection Init** (8-12h)
   - Blocks clean deployments
   - Low complexity, high value
   - **Owner**: Infrastructure lead

3. **H2: Deep Health Checks** (6-8h)
   - Required for k8s readiness probes
   - Enables blue/green deployments
   - **Owner**: Backend lead

4. **Document Caqti Migration** (2h)
   - Update DEVELOPER.md, OPERATIONS.md
   - Fix libpq → Caqti references
   - **Owner**: Tech writer

**Sprint Total**: 26-36 hours

---

### Next Quarter Priorities

**Q1 2025: Production Hardening**
- H1: Prometheus Metrics (16-22h)
- H3: Agent Timeout (4-6h)
- H4: Job Retry Policy (10-14h)
- H5: Query Pagination (6-8h)
- M1: Testing Docs (3-4h)
- M8: Docker Builds (6-8h)

**Q2 2025: User Features**
- M3: Query Syntax Docs (4-6h)
- M6: PGN Export Endpoint (4-6h)
- M7: Bulk Export Tool (8-12h)
- M9: OpenAPI Validation (10-14h)

**Q3 2025: Scalability**
- H6: Redis Pooling (8-12h)
- M14: Worker Auto-Scaling (12-16h)
- Add read replicas for Postgres
- Multi-region Qdrant replication

**Q4 2025: Polish**
- M10: Structured Logging (4-8h)
- M11: Admin CLI (8-12h)
- M12: Load Testing Suite (6-10h)
- L1-L8: Security/Config improvements (48-74h)

---

## Part 8: Comparison with REVIEW_v2.md

### Tasks Now Complete (Since v2.0)

1. **✅ Vector Upload to Qdrant** (v2.0 Task #13)
   - Implemented in embedding_worker.ml:142-192
   - Retry logic with 3 attempts
   - Payload enrichment from Postgres

2. **✅ Secret Sanitization** (v2.0 Task #16)
   - Implemented in lib/core/sanitizer.ml
   - Regex patterns for API keys, DB URLs
   - Applied throughout error paths

3. **✅ Connection Pooling** (v2.0 Task #5)
   - Caqti pool with configurable size
   - Pool stats via /metrics endpoint
   - Mutex-protected in_use/waiting counters

4. **✅ Metrics Endpoint** (v2.0 Task #3 partial)
   - `/metrics` exposing DB pool gauges
   - Foundation for Prometheus expansion
   - Note: Full Prometheus instrumentation still needed (H1)

### Tasks Still Outstanding from v2.0

1. **⚠️ SQL Injection Risks** → **RESOLVED** via Caqti
   - v2.0 Task #1 concerned string concatenation
   - Caqti migration uses parameterized queries throughout
   - repo_postgres_caqti.ml:138-197 builds dynamic params safely

2. **⚠️ API Rate Limiting** → **REMAINS C1**
   - Still critical blocker
   - Unchanged priority

3. **⚠️ Integration Tests** → **PARTIALLY RESOLVED**
   - v2.0 Task #4 cited missing end-to-end tests
   - test/test_integration.ml now has 3 workflows (ingest, job lifecycle, hybrid executor)
   - But agent evaluation, graceful shutdown, pagination tests still missing

4. **⚠️ Deep Health Checks** → **REMAINS H2**
   - Still needed for k8s
   - Unchanged priority

5. **⚠️ Agent Evaluator Tests** → **REMAINS M-priority**
   - test/test_agent_evaluator.ml doesn't exist
   - Downgraded from High to Medium (agent is optional feature)

### New Tasks Identified in v3.0

1. **C2: Qdrant Collection Init** (new critical)
2. **H3: Agent Timeout** (new high)
3. **H4: Job Retry Policy** (new high)
4. **H5: Query Pagination** (new high)
5. **H6: Redis Pooling** (new high)
6. **M1-M15**: 15 medium-priority tasks (testing, docs, tooling)
7. **L1-L8**: 8 low-priority tasks (security headers, config tests, etc.)

### Effort Delta

| Review | Critical | High | Medium | Low | Total |
|--------|----------|------|--------|-----|-------|
| v2.0 | 40-58h | 80-116h | 82-130h | 18-30h | 220-334h |
| v3.0 | 18-26h | 52-76h | 98-150h | 48-74h | 216-326h |
| Delta | **-22h** | **-40h** | **+16h** | **+30h** | **-8h** |

**Analysis**: Critical/high-priority work reduced due to Caqti migration resolving SQL injection and connection pooling. Medium/low priorities increased due to new operational/documentation tasks identified.

---

## Appendix A: Quick Reference

### File Creation Checklist

**New Modules:**
- lib/api/rate_limiter.ml + .mli
- lib/observability/metrics.ml + .mli
- lib/cli/export_command.ml + .mli
- docs/TESTING.md
- docs/QUERY_SYNTAX.md
- docs/MONITORING.md
- docs/PERFORMANCE.md
- docs/SECURITY.md
- docs/DISASTER_RECOVERY.md
- docs/dashboards/chessmate.json
- Dockerfile.api
- Dockerfile.worker
- Makefile

**Test Files:**
- test/test_rate_limiter.ml
- test/test_agent_evaluator.ml
- test/test_openings.ml
- test/load/ (directory with locust/wrk scripts)

### Configuration Variables to Add

```bash
# Rate limiting
CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE=60

# Qdrant
QDRANT_COLLECTION_NAME=positions
QDRANT_VECTOR_SIZE=1536

# Agent
AGENT_TIMEOUT_SECONDS=30
AGENT_COST_INPUT_PER_1K=0.002
AGENT_COST_OUTPUT_PER_1K=0.006
AGENT_COST_REASONING_PER_1K=0.001

# Redis
AGENT_CACHE_REDIS_POOL_SIZE=10

# Worker
CHESSMATE_WORKER_METRICS_PORT=9091

# Logging
CHESSMATE_LOG_LEVEL=info
AGENT_TELEMETRY_SAMPLE_RATE=1.0
```

### Migration Scripts Needed

```sql
-- migrations/0008_add_job_retry_count.sql
ALTER TABLE embedding_jobs ADD COLUMN retry_count INTEGER DEFAULT 0;
ALTER TABLE embedding_jobs ADD COLUMN next_retry_after TIMESTAMPTZ;
CREATE INDEX idx_embedding_jobs_retry ON embedding_jobs(status, retry_count, next_retry_after)
  WHERE status = 'pending';
```

---

## Appendix B: Testing Strategy

### Unit Test Coverage Targets

| Module | Current | Target | Priority |
|--------|---------|--------|----------|
| lib/chess/* | ~80% | 90% | Low (stable) |
| lib/storage/* | ~60% | 85% | High (critical path) |
| lib/query/* | ~50% | 80% | High (complex logic) |
| lib/agents/* | ~40% | 70% | Medium (optional feature) |
| lib/core/* | ~70% | 90% | High (shared utilities) |

### Integration Test Scenarios

**Existing** (test/test_integration.ml):
1. Ingest workflow persists data ✅
2. Embedding job lifecycle completes ✅
3. Hybrid executor surfaces ingested game ✅

**To Add**:
4. Agent evaluation end-to-end (mock GPT-5, verify score in response)
5. Graceful shutdown with in-flight requests (send SIGTERM during query)
6. Query pagination (ingest 100 games, verify offset/limit)
7. Rate limiting (send 70 requests, verify 10 get 429)
8. Qdrant unavailable fallback (stop Qdrant, verify metadata-only results)
9. Worker retry policy (mock transient error, verify retry scheduled)
10. Deep health checks (stop Redis, verify /health/ready returns 503)

### Load Testing Benchmarks

**Target Performance** (50 concurrent users, p95):
- GET /query: < 500ms
- POST /query: < 500ms
- GET /games/{id}/pgn: < 100ms
- GET /health: < 10ms
- GET /metrics: < 50ms

**Resource Limits** (per instance):
- CPU: 2 cores (sustained)
- Memory: 1GB RSS
- DB connections: 10 (pool size)
- Redis connections: 10 (pool size)

---

## Appendix C: Glossary

- **Caqti**: Composable async queries for OCaml (database abstraction)
- **ECO**: Encyclopedia of Chess Openings (classification system)
- **FEN**: Forsyth-Edwards Notation (position representation)
- **PGN**: Portable Game Notation (game recording format)
- **Qdrant**: Vector similarity search engine
- **p95**: 95th percentile latency (slowest 5% of requests)
- **RTO**: Recovery Time Objective (max downtime)
- **RPO**: Recovery Point Objective (max data loss)

---

## Change Log

### 2025-10-10: v3.0 Initial Review
- Conducted post-Caqti migration analysis
- Identified 31 outstanding tasks (216-326 hours)
- Documented recent achievements (vector upload, sanitization, metrics)
- Compared against REVIEW_v2.md baseline
- Created prioritized roadmap with quarterly milestones

---

**Next Review**: 2025-11-10 (post-Q1 production hardening sprint)
