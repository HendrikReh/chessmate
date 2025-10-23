open! Base

type status = Disabled | Closed | Half_open | Open
type metrics_hook = open_:bool -> unit

type t = {
  mutable enabled : bool;
  mutable threshold : int;
  mutable cooloff : float;
  mutable failure_count : int;
  mutable open_until : float option;
  mutable half_open : bool;
  metrics_hook : metrics_hook;
}

let default_metrics_hook ~open_ = Api_metrics.set_agent_circuit_state ~open_

let create ?(metrics_hook = default_metrics_hook) () =
  {
    enabled = false;
    threshold = 0;
    cooloff = 0.;
    failure_count = 0;
    open_until = None;
    half_open = false;
    metrics_hook;
  }

let configure t ~threshold ~cooloff_seconds =
  if threshold <= 0 then (
    t.enabled <- false;
    t.threshold <- 0;
    t.cooloff <- 0.;
    t.failure_count <- 0;
    t.open_until <- None;
    t.half_open <- false;
    t.metrics_hook ~open_:false)
  else (
    t.enabled <- true;
    t.threshold <- threshold;
    t.cooloff <- cooloff_seconds;
    t.failure_count <- 0;
    t.open_until <- None;
    t.half_open <- false;
    t.metrics_hook ~open_:false)

let current_status t =
  if not t.enabled then Disabled
  else
    let now = Unix.gettimeofday () in
    match t.open_until with
    | Some until when Float.(now < until) -> Open
    | Some _ -> Half_open
    | None -> if t.half_open then Half_open else Closed

let should_allow t =
  if not t.enabled then true
  else
    let now = Unix.gettimeofday () in
    match t.open_until with
    | Some until when Float.(now < until) -> false
    | Some _ ->
        t.open_until <- None;
        t.half_open <- true;
        t.metrics_hook ~open_:false;
        true
    | None -> true

let record_success t =
  if t.enabled then (
    t.failure_count <- 0;
    t.open_until <- None;
    t.half_open <- false;
    t.metrics_hook ~open_:false)

let record_failure t =
  if t.enabled then (
    t.failure_count <- t.failure_count + 1;
    t.half_open <- false;
    let now = Unix.gettimeofday () in
    if t.failure_count >= t.threshold then (
      t.failure_count <- 0;
      t.open_until <- Some (now +. t.cooloff);
      t.metrics_hook ~open_:true))

let status_to_string = function
  | Disabled -> "disabled"
  | Closed -> "closed"
  | Half_open -> "half_open"
  | Open -> "open"
