open! Base
open Stdio
module Registry = Metrics.Registry

type ingest_result = [ `Stored | `Skipped ]
type ingest_outcome = [ `Success | `Failure ]

type metric_handles = {
  ingest_games : Metrics.Counter.t;
  ingest_runs : Metrics.Counter.t;
  ingest_duration : Metrics.Summary.t;
  embedding_pending : Metrics.Gauge.t;
}

let metrics_ref : (Registry.t * metric_handles) option ref = ref None
let namespace = "chessmate"
let subsystem = "cli"

let log_metric_error context err =
  eprintf "[metrics][warn] %s failed: %s\n%!" context (Error.to_string_hum err)

let record_or_warn context f =
  match f () with Ok () -> () | Error err -> log_metric_error context err

let create_metrics registry =
  let counter ?label_names ~help name =
    Metrics.Counter.create ~registry ?label_names ~namespace ~subsystem ~help
      name
    |> Or_error.ok_exn
  in
  let summary ?label_names ~help name =
    Metrics.Summary.create ~registry ?label_names ~namespace ~subsystem ~help
      name
    |> Or_error.ok_exn
  in
  let gauge ?label_names ~help name =
    Metrics.Gauge.create ~registry ?label_names ~namespace ~subsystem ~help name
    |> Or_error.ok_exn
  in
  {
    ingest_games =
      counter ~label_names:[ "result" ]
        ~help:"Games processed during CLI ingest runs" "ingest_games_total";
    ingest_runs =
      counter ~label_names:[ "outcome" ]
        ~help:"CLI ingest runs grouped by outcome" "ingest_runs_total";
    ingest_duration =
      summary ~label_names:[ "outcome" ]
        ~help:"Duration of CLI ingest runs in seconds"
        "ingest_run_duration_seconds";
    embedding_pending =
      gauge ~help:"Pending embedding jobs observed before ingest run"
        "embedding_pending_jobs";
  }

let ensure_metrics () =
  let registry = Registry.current () in
  match !metrics_ref with
  | Some (active_registry, handles) when phys_equal active_registry registry ->
      handles
  | _ ->
      let handles = create_metrics registry in
      metrics_ref := Some (registry, handles);
      handles

let result_label = function `Stored -> "stored" | `Skipped -> "skipped"
let outcome_label = function `Success -> "success" | `Failure -> "failure"

let record_ingest_game ~result =
  let metrics = ensure_metrics () in
  let label = result_label result in
  record_or_warn "ingest_games_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ label ] metrics.ingest_games)

let record_ingest_run ~outcome ~duration_s =
  let metrics = ensure_metrics () in
  let label = outcome_label outcome in
  record_or_warn "ingest_runs_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ label ] metrics.ingest_runs);
  record_or_warn "ingest_run_duration_seconds" (fun () ->
      Metrics.Summary.observe ~label_values:[ label ] duration_s
        metrics.ingest_duration)

let set_embedding_pending_jobs count =
  let metrics = ensure_metrics () in
  record_or_warn "embedding_pending_jobs" (fun () ->
      Metrics.Gauge.set (Float.of_int count) metrics.embedding_pending)

let reset_for_tests () =
  let fresh_registry = Registry.create () in
  Registry.use fresh_registry;
  metrics_ref := None
