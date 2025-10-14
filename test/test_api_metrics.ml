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

let find_metric name lines =
  List.find_map lines ~f:(fun line ->
      match String.lsplit2 ~on:' ' line with
      | Some (key, value) when String.equal key name -> Some value
      | _ -> None)

let test_request_metrics () =
  Api_metrics.reset_for_tests ();
  Api_metrics.record_request ~route:"GET /query" ~latency_ms:10. ~status:200;
  Api_metrics.record_request ~route:"GET /query" ~latency_ms:20. ~status:500;
  Api_metrics.record_request ~route:"GET /health" ~latency_ms:5. ~status:200;
  let lines = Api_metrics.render () in
  let count = find_metric "api_request_total{route=\"GET /query\"}" lines in
  check (option string) "request count" (Some "2") count;
  let errors =
    find_metric "api_request_errors_total{route=\"GET /query\"}" lines
  in
  check (option string) "error count" (Some "1") errors;
  match
    find_metric "api_request_latency_ms_p50{route=\"GET /query\"}" lines
  with
  | Some _ -> ()
  | None -> fail "missing latency metric"

let test_agent_metrics () =
  Api_metrics.reset_for_tests ();
  Api_metrics.record_agent_cache_hit ();
  Api_metrics.record_agent_cache_hit ();
  Api_metrics.record_agent_cache_miss ();
  Api_metrics.record_agent_evaluation ~success:true ~latency_ms:12.5;
  Api_metrics.record_agent_evaluation ~success:false ~latency_ms:7.5;
  Api_metrics.set_agent_circuit_state ~open_:true;
  let lines = Api_metrics.render () in
  let hits = find_metric "agent_cache_hits_total" lines in
  check (option string) "cache hits" (Some "2") hits;
  let misses = find_metric "agent_cache_misses_total" lines in
  check (option string) "cache misses" (Some "1") misses;
  let evals = find_metric "agent_evaluations_total" lines in
  check (option string) "evaluations" (Some "2") evals;
  let errors = find_metric "agent_evaluation_errors_total" lines in
  check (option string) "eval errors" (Some "1") errors;
  let circuit = find_metric "agent_circuit_breaker_state" lines in
  check (option string) "circuit state" (Some "1") circuit;
  ()

let test_request_metric_escapes_route () =
  Api_metrics.reset_for_tests ();
  Api_metrics.record_request ~route:"GET /metrics\"bad\\name\n" ~latency_ms:5.
    ~status:200;
  let lines = Api_metrics.render () in
  let metric_line =
    List.find lines ~f:(fun line ->
        String.is_substring line ~substring:"api_request_total{route=")
  in
  match metric_line with
  | None -> fail "request metric missing"
  | Some line ->
      check bool "escapes quote" true
        (String.is_substring line ~substring:"\\\"");
      check bool "escapes backslash" true
        (String.is_substring line ~substring:"\\\\");
      check bool "escapes newline" true
        (String.is_substring line ~substring:"\\n")

let suite =
  [
    test_case "request metrics aggregate" `Quick test_request_metrics;
    test_case "agent metrics aggregate" `Quick test_agent_metrics;
    test_case "request metrics escape labels" `Quick
      test_request_metric_escapes_route;
  ]
