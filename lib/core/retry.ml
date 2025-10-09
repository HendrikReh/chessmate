(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search

    Copyright (C) 2025 Hendrik Reh

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*)

open! Base

type 'a attempt =
  | Resolved of 'a Or_error.t
  | Retry of Error.t

let apply_jitter ~jitter ~random delay =
  if Float.(jitter <= 0.) then delay
  else
    let offset = (random () *. (2. *. jitter)) -. jitter in
    let factor = 1. +. offset in
    Float.max 0. (delay *. factor)

let with_backoff
    ?(sleep = Unix.sleepf)
    ?random
    ?on_retry
    ~max_attempts
    ~initial_delay
    ~multiplier
    ?(max_delay = Float.infinity)
    ~jitter
    ~f
    ()
  =
  if max_attempts < 1 then
    invalid_arg "Retry.with_backoff: max_attempts must be >= 1";
  let random =
    match random with
    | Some fn -> fn
    | None -> (fun () -> Stdlib.Random.float 1.0)
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
