open! Base
open Stdio
module Registry = Metrics.Registry

type metric_handles = {
  job_counter : Metrics.Counter.t;
  fen_chars : Metrics.Summary.t;
  jobs_per_min : Metrics.Gauge.t;
  chars_per_sec : Metrics.Gauge.t;
  queue_depth : Metrics.Gauge.t;
}

let metrics_ref : (Registry.t * metric_handles) option ref = ref None
let namespace = "chessmate"
let subsystem = "worker"

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
    job_counter =
      counter ~label_names:[ "outcome" ]
        ~help:"Embedding jobs handled by the worker" "embedding_jobs_total";
    fen_chars =
      summary ~help:"Total FEN characters processed per job"
        "embedding_fen_characters_total";
    jobs_per_min =
      gauge ~help:"Estimated embedding throughput in jobs per minute"
        "embedding_jobs_per_minute";
    chars_per_sec =
      gauge ~help:"Estimated rate of FEN characters processed per second"
        "embedding_characters_per_second";
    queue_depth =
      gauge ~help:"Observed pending embedding jobs" "embedding_pending_jobs";
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

let outcome_label failed = if failed then "failed" else "succeeded"

let record_job_completion ~failed ~fen_chars =
  let handles = ensure_metrics () in
  let outcome = outcome_label failed in
  record_or_warn "embedding_jobs_total" (fun () ->
      Metrics.Counter.inc_one ~label_values:[ outcome ] handles.job_counter);
  record_or_warn "embedding_fen_characters_total" (fun () ->
      Metrics.Summary.observe fen_chars handles.fen_chars)

let observe_throughput ~jobs_per_min ~chars_per_sec =
  let handles = ensure_metrics () in
  record_or_warn "embedding_jobs_per_minute" (fun () ->
      Metrics.Gauge.set jobs_per_min handles.jobs_per_min);
  record_or_warn "embedding_characters_per_second" (fun () ->
      Metrics.Gauge.set chars_per_sec handles.chars_per_sec)

let set_queue_depth depth =
  let handles = ensure_metrics () in
  record_or_warn "embedding_pending_jobs" (fun () ->
      Metrics.Gauge.set (Float.of_int depth) handles.queue_depth)

let reset_for_tests () =
  let fresh_registry = Registry.create () in
  Registry.use fresh_registry;
  metrics_ref := None
