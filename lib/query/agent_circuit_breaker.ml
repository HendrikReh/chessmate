open! Base

type status = Disabled | Closed | Half_open | Open

type t = {
  mutable enabled : bool;
  mutable threshold : int;
  mutable cooloff : float;
  mutable failure_count : int;
  mutable open_until : float option;
  mutable half_open : bool;
}

let state : t =
  {
    enabled = false;
    threshold = 0;
    cooloff = 0.;
    failure_count = 0;
    open_until = None;
    half_open = false;
  }

let reset_metrics () = Api_metrics.set_agent_circuit_state ~open_:false

let configure ~threshold ~cooloff_seconds =
  if threshold <= 0 then (
    state.enabled <- false;
    state.threshold <- 0;
    state.cooloff <- 0.;
    state.failure_count <- 0;
    state.open_until <- None;
    state.half_open <- false;
    reset_metrics ())
  else (
    state.enabled <- true;
    state.threshold <- threshold;
    state.cooloff <- cooloff_seconds;
    state.failure_count <- 0;
    state.open_until <- None;
    state.half_open <- false;
    reset_metrics ())

let current_status () =
  if not state.enabled then Disabled
  else
    let now = Unix.gettimeofday () in
    match state.open_until with
    | Some until when Float.(now < until) -> Open
    | Some _ -> Half_open
    | None -> if state.half_open then Half_open else Closed

let should_allow () =
  if not state.enabled then true
  else
    let now = Unix.gettimeofday () in
    match state.open_until with
    | Some until when Float.(now < until) -> false
    | Some _ ->
        state.open_until <- None;
        state.half_open <- true;
        Api_metrics.set_agent_circuit_state ~open_:false;
        true
    | None -> true

let record_success () =
  if state.enabled then (
    state.failure_count <- 0;
    state.open_until <- None;
    state.half_open <- false;
    Api_metrics.set_agent_circuit_state ~open_:false)

let record_failure () =
  if state.enabled then (
    state.failure_count <- state.failure_count + 1;
    state.half_open <- false;
    let now = Unix.gettimeofday () in
    if state.failure_count >= state.threshold then (
      state.failure_count <- 0;
      state.open_until <- Some (now +. state.cooloff);
      Api_metrics.set_agent_circuit_state ~open_:true))

let status_to_string = function
  | Disabled -> "disabled"
  | Closed -> "closed"
  | Half_open -> "half_open"
  | Open -> "open"
