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

let collect_lines () =
  Lwt_main.run (Api_metrics.collect ())
  |> String.split_lines
  |> List.filter ~f:(fun line -> not (String.is_empty (String.strip line)))

let find_metric prefix lines =
  List.find_map lines ~f:(fun line ->
      if String.is_prefix line ~prefix then
        String.lsplit2 line ~on:' ' |> Option.map ~f:snd
      else None)

let test_request_metrics () =
  Api_metrics.reset_for_tests ();
  Api_metrics.record_request ~route:"GET /query" ~latency_ms:10. ~status:200;
  Api_metrics.record_request ~route:"GET /query" ~latency_ms:20. ~status:500;
  Api_metrics.record_request ~route:"GET /health" ~latency_ms:5. ~status:200;
  let lines = collect_lines () in
  let query_ok =
    find_metric
      "chessmate_api_requests_total{route=\"GET /query\",status=\"200\"}" lines
  in
  check (option string) "query 200 count" (Some "1") query_ok;
  let query_error =
    find_metric
      "chessmate_api_requests_total{route=\"GET /query\",status=\"500\"}" lines
  in
  check (option string) "query 500 count" (Some "1") query_error;
  let latency_sum =
    find_metric
      "chessmate_api_request_duration_seconds_sum{route=\"GET /query\"}" lines
  in
  match latency_sum with
  | None -> fail "missing latency sum metric"
  | Some value ->
      let parsed = Float.of_string value in
      check bool "latency sum > 0" true Float.(parsed > 0.0)

let test_agent_metrics () =
  Api_metrics.reset_for_tests ();
  Api_metrics.record_agent_cache_hit ();
  Api_metrics.record_agent_cache_hit ();
  Api_metrics.record_agent_cache_miss ();
  Api_metrics.record_agent_evaluation ~success:true ~latency_ms:12.5;
  Api_metrics.record_agent_evaluation ~success:false ~latency_ms:7.5;
  Api_metrics.set_agent_circuit_state ~open_:true;
  let lines = collect_lines () in
  let hits =
    find_metric "chessmate_api_agent_cache_total{state=\"hit\"}" lines
  in
  check (option string) "cache hits" (Some "2") hits;
  let misses =
    find_metric "chessmate_api_agent_cache_total{state=\"miss\"}" lines
  in
  check (option string) "cache misses" (Some "1") misses;
  let eval_success =
    find_metric "chessmate_api_agent_evaluations_total{outcome=\"success\"}"
      lines
  in
  check (option string) "successful evaluations" (Some "1") eval_success;
  let eval_failure =
    find_metric "chessmate_api_agent_evaluations_total{outcome=\"failure\"}"
      lines
  in
  check (option string) "failed evaluations" (Some "1") eval_failure;
  let latency_sum =
    find_metric
      "chessmate_api_agent_evaluation_latency_seconds_sum{outcome=\"success\"}"
      lines
  in
  (match latency_sum with
  | None -> fail "missing latency sum"
  | Some value ->
      let parsed = Float.of_string value in
      check bool "latency sum > 0" true Float.(parsed > 0.0));
  let circuit = find_metric "chessmate_api_agent_circuit_breaker_state" lines in
  check (option string) "circuit state" (Some "1") circuit

let test_request_metric_escapes_route () =
  Api_metrics.reset_for_tests ();
  Api_metrics.record_request ~route:"GET /metrics\"bad\\name\n" ~latency_ms:5.
    ~status:200;
  let lines = collect_lines () in
  let metric_line =
    List.find lines ~f:(fun line ->
        String.is_prefix line
          "chessmate_api_requests_total{route=\"GET \
           /metrics\\\"bad\\\\name\\n\",status=\"200\"}")
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
