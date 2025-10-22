open! Base

type 'a attempt = Resolved of 'a Or_error.t | Retry of Error.t

let apply_jitter ~jitter ~random delay =
  if Float.(jitter <= 0.) then delay
  else
    let offset = (random () *. (2. *. jitter)) -. jitter in
    let factor = 1. +. offset in
    Float.max 0. (delay *. factor)

let with_backoff ?(sleep = Unix.sleepf) ?random ?on_retry ~max_attempts
    ~initial_delay ~multiplier ?(max_delay = Float.infinity) ~jitter ~f () =
  if max_attempts < 1 then
    invalid_arg "Retry.with_backoff: max_attempts must be >= 1";
  let random =
    match random with
    | Some fn -> fn
    | None -> fun () -> Stdlib.Random.float 1.0
  in
  let clamp_delay delay = Float.min max_delay delay in
  let rec loop attempt current_delay =
    match f ~attempt with
    | Resolved result -> result
    | Retry error ->
        if attempt >= max_attempts then Error error
        else
          let jittered_delay = apply_jitter ~jitter ~random current_delay in
          (match on_retry with
          | None -> ()
          | Some callback -> callback ~attempt ~delay:jittered_delay error);
          sleep jittered_delay;
          let next_delay = clamp_delay (current_delay *. multiplier) in
          loop (attempt + 1) next_delay
  in
  loop 1 (Float.max 0. initial_delay)
