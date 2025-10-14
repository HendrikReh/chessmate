(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search
    Copyright (C) 2025 Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>

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
open Alcotest
open Chessmate

let to_error msg = Error.of_string msg

let test_retries_until_success () =
  let sleeps = ref [] in
  let sleep seconds = sleeps := seconds :: !sleeps in
  let callbacks = ref [] in
  let f ~attempt =
    match attempt with
    | 1 -> Retry.Retry (to_error "transient 1")
    | 2 -> Retry.Retry (to_error "transient 2")
    | _ -> Retry.Resolved (Ok "ok")
  in
  match
    Retry.with_backoff ~sleep ~max_attempts:5 ~initial_delay:0.1 ~multiplier:2.0
      ~jitter:0.0
      ~on_retry:(fun ~attempt ~delay err ->
        callbacks := (attempt, delay, Error.to_string_hum err) :: !callbacks)
      ~f ()
  with
  | Ok "ok" ->
      let recorded = List.rev !sleeps in
      check (list (float 1e-6)) "sleep sequence" [ 0.1; 0.2 ] recorded;
      let observed = List.rev !callbacks in
      check
        (list (triple int (float 1e-6) string))
        "retry callbacks"
        [ (1, 0.1, "transient 1"); (2, 0.2, "transient 2") ]
        observed
  | Ok other -> failf "unexpected success payload %s" other
  | Error err -> failf "unexpected final error %s" (Error.to_string_hum err)

let test_exhausts_attempts () =
  let attempt_counter = ref 0 in
  let f ~attempt =
    attempt_counter := attempt;
    Retry.Retry (to_error "always failing")
  in
  match
    Retry.with_backoff ~max_attempts:3 ~initial_delay:0.05 ~multiplier:1.5
      ~jitter:0.0 ~f ()
  with
  | Ok _ -> fail "expected failure after exhausting attempts"
  | Error err ->
      check string "final error" "always failing" (Error.to_string_hum err);
      check int "attempt count" 3 !attempt_counter

let test_applies_jitter () =
  let sleeps = ref [] in
  let random_values = ref [ 0.75; 0.25 ] in
  let random () =
    match !random_values with
    | [] -> 0.5
    | value :: rest ->
        random_values := rest;
        value
  in
  let sleep seconds = sleeps := seconds :: !sleeps in
  let attempts = ref 0 in
  let f ~attempt =
    Int.incr attempts;
    if attempt < 3 then Retry.Retry (to_error "transient")
    else Retry.Resolved (Ok ())
  in
  match
    Retry.with_backoff ~sleep ~random ~max_attempts:3 ~initial_delay:0.2
      ~multiplier:2.0 ~jitter:0.3 ~f ()
  with
  | Error err -> failf "unexpected failure %s" (Error.to_string_hum err)
  | Ok () ->
      let recorded = List.rev !sleeps in
      (* With jitter 0.3 and random values 0.75 then 0.25, the factors become
         1 + ((0.75 * 0.6) - 0.3) = 1.15 and 1 + ((0.25 * 0.6) - 0.3) = 0.85. *)
      let expected = [ 0.2 *. 1.15; 0.4 *. 0.85 ] in
      check (list (float 1e-6)) "jittered delays" expected recorded

let suite =
  [
    test_case "retries until success" `Quick test_retries_until_success;
    test_case "limits retry attempts" `Quick test_exhausts_attempts;
    test_case "applies jitter" `Quick test_applies_jitter;
  ]
