open! Base
open Stdio
module Registry = Metrics.Registry

type metric_handles = {
  request_total : Metrics.Counter.t;
  request_latency : Metrics.Histogram.t;
  agent_cache_total : Metrics.Counter.t;
  agent_eval_total : Metrics.Counter.t;
  agent_eval_latency : Metrics.Summary.t;
  agent_circuit_breaker : Metrics.Gauge.t;
  db_pool_size : Metrics.Gauge.t;
  db_pool_wait_ratio : Metrics.Gauge.t;
  query_embedding_total : Metrics.Counter.t;
  query_embedding_latency : Metrics.Histogram.t;
}

let metrics_ref : (Registry.t * metric_handles) option ref = ref None
let namespace = "chessmate"
let subsystem = "api"

let log_metric_error context err =
  eprintf "[metrics][warn] %s failed: %s\n%!" context (Error.to_string_hum err)

let record_or_warn context f =
  match f () with Ok () -> () | Error err -> log_metric_error context err

let create_metrics registry =
  let create_counter ?label_names ~help name =
    Metrics.Counter.create ~registry ?label_names ~namespace ~subsystem ~help
      name
    |> Or_error.ok_exn
  in
  let create_histogram ?label_names ~help name =
    Metrics.Histogram.create ~registry ?label_names ~namespace ~subsystem ~help
      name
    |> Or_error.ok_exn
  in
  let create_summary ?label_names ~help name =
    Metrics.Summary.create ~registry ?label_names ~namespace ~subsystem ~help
      name
    |> Or_error.ok_exn
  in
  let create_gauge ?label_names ~help name =
    Metrics.Gauge.create ~registry ?label_names ~namespace ~subsystem ~help name
    |> Or_error.ok_exn
  in
  {
    request_total =
      create_counter ~label_names:[ "route"; "status" ]
        ~help:"Total HTTP responses produced by the Chessmate API"
        "requests_total";
    request_latency =
      create_histogram ~label_names:[ "route" ]
        ~help:"Latency of handled HTTP requests in seconds"
        "request_duration_seconds";
    agent_cache_total =
      create_counter ~label_names:[ "state" ] ~help:"Agent cache interactions"
        "agent_cache_total";
    agent_eval_total =
      create_counter ~label_names:[ "outcome" ]
        ~help:"Agent evaluation attempts" "agent_evaluations_total";
    agent_eval_latency =
      create_summary ~label_names:[ "outcome" ]
        ~help:"Latency of agent evaluations in seconds"
        "agent_evaluation_latency_seconds";
    agent_circuit_breaker =
      create_gauge ~help:"Agent circuit breaker state (1=open,0=closed)"
        "agent_circuit_breaker_state";
    db_pool_size =
      create_gauge ~label_names:[ "state" ]
        ~help:"Postgres connection pool utilisation" "db_pool_connections";
    db_pool_wait_ratio =
      create_gauge
        ~help:"Ratio of waiting clients to total capacity in the Postgres pool"
        "db_pool_wait_ratio";
    query_embedding_total =
      create_counter ~label_names:[ "source" ]
        ~help:"Query embedding attempts by source (service vs fallback)"
        "query_embedding_total";
    query_embedding_latency =
      create_histogram ~label_names:[ "source" ]
        ~help:"Latency of query embedding resolution in seconds"
        "query_embedding_duration_seconds";
  }

let ensure_metrics () =
  let registry = Registry.current () in
  match !metrics_ref with
  | Some (active_registry, metrics) when phys_equal active_registry registry ->
      metrics
  | _ ->
      let metrics = create_metrics registry in
      metrics_ref := Some (registry, metrics);
      metrics

let record_request ~route ~latency_ms ~status =
  let metrics = ensure_metrics () in
  let status_value = Int.to_string status in
  record_or_warn "api_requests_total" (fun () ->
      Metrics.Counter.inc ~label_values:[ route; status_value ]
        metrics.request_total);
  let latency_seconds = latency_ms /. 1000.0 in
  record_or_warn "api_request_duration_seconds" (fun () ->
      Metrics.Histogram.observe ~label_values:[ route ] latency_seconds
        metrics.request_latency)

let record_agent_cache_hit () =
  let metrics = ensure_metrics () in
  record_or_warn "agent_cache_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ "hit" ] metrics.agent_cache_total)

let record_agent_cache_miss () =
  let metrics = ensure_metrics () in
  record_or_warn "agent_cache_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ "miss" ] metrics.agent_cache_total)

let record_agent_evaluation ~success ~latency_ms =
  let metrics = ensure_metrics () in
  let outcome = if success then "success" else "failure" in
  record_or_warn "agent_evaluations_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ outcome ] metrics.agent_eval_total);
  let latency_seconds = latency_ms /. 1000.0 in
  record_or_warn "agent_evaluation_latency_seconds" (fun () ->
      Metrics.Summary.observe ~label_values:[ outcome ] latency_seconds
        metrics.agent_eval_latency)

let set_agent_circuit_state ~open_ =
  let metrics = ensure_metrics () in
  let value = if open_ then 1.0 else 0.0 in
  record_or_warn "agent_circuit_breaker_state" (fun () ->
      Metrics.Gauge.set value metrics.agent_circuit_breaker)

let set_db_pool_stats ~capacity ~in_use ~available ~waiting ~wait_ratio =
  let metrics = ensure_metrics () in
  let states =
    [
      ("capacity", Float.of_int capacity);
      ("in_use", Float.of_int in_use);
      ("available", Float.of_int available);
      ("waiting", Float.of_int waiting);
    ]
  in
  List.iter states ~f:(fun (label, value) ->
      record_or_warn "db_pool_connections" (fun () ->
          Metrics.Gauge.set ~label_values:[ label ] value metrics.db_pool_size));
  record_or_warn "db_pool_wait_ratio" (fun () ->
      Metrics.Gauge.set wait_ratio metrics.db_pool_wait_ratio)

let record_query_embedding ~source ~latency_ms =
  let metrics = ensure_metrics () in
  record_or_warn "query_embedding_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ source ]
        metrics.query_embedding_total);
  let latency_seconds = latency_ms /. 1000.0 in
  record_or_warn "query_embedding_duration_seconds" (fun () ->
      Metrics.Histogram.observe ~label_values:[ source ] latency_seconds
        metrics.query_embedding_latency)

let registry () =
  let _ = ensure_metrics () in
  Registry.current ()

let collect () = Registry.collect ~registry:(registry ()) ()

let reset_for_tests () =
  let fresh_registry = Registry.create () in
  Registry.use fresh_registry;
  metrics_ref := None
