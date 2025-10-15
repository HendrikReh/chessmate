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

let sample_agent =
  {
    Config.Api.api_key = Some "sk-test";
    endpoint = "https://api.openai.example/v1/responses";
    model = Some "gpt-5";
    reasoning_effort = Agents_gpt5_client.Effort.Medium;
    verbosity = None;
    request_timeout_seconds = 15.;
    cache =
      Config.Api.Agent_cache.Redis
        { url = "redis://localhost:6379"; namespace = None; ttl_seconds = None };
    candidate_multiplier = 5;
    candidate_max = 25;
    circuit_breaker_threshold = 5;
    circuit_breaker_cooloff_seconds = 60.;
  }

let sample_api_config =
  {
    Config.Api.database_url = "postgres://localhost/chessmate";
    qdrant_url = "http://localhost:6333";
    port = 8080;
    agent = sample_agent;
    rate_limit = None;
    qdrant_collection = None;
    max_request_body_bytes = Some 1_048_576;
  }

let sample_worker_config =
  {
    Config.Worker.database_url = "postgres://localhost/chessmate";
    openai_api_key = "sk-worker";
    openai_endpoint = "https://api.openai.example/v1/embeddings";
    batch_size = 16;
    health_port = 9000;
    prometheus_port = None;
  }

let status_to_string = function
  | `Ok -> "ok"
  | `Degraded -> "degraded"
  | `Error -> "error"

let check_status label expected summary =
  let actual = status_to_string summary.Health.status in
  check string label expected actual

let dummy_postgres = lazy (Or_error.error_string "unused")

let test_api_ok () =
  let overrides =
    {
      Health.Test_hooks.empty with
      postgres = Some (fun () -> `Ok (Some "pool"));
      qdrant = Some (fun () -> `Ok (Some "healthz"));
      redis = Some (fun () -> `Ok None);
      openai = Some (fun () -> `Ok (Some "model=gpt-5"));
    }
  in
  Health.Test_hooks.with_overrides overrides ~f:(fun () ->
      let summary =
        Health.Api.summary ~postgres:dummy_postgres ~config:sample_api_config ()
      in
      check_status "status" "ok" summary;
      check int "check count" 4 (List.length summary.Health.checks))

let test_api_degraded_on_redis_failure () =
  let overrides =
    {
      Health.Test_hooks.empty with
      postgres = Some (fun () -> `Ok None);
      qdrant = Some (fun () -> `Ok None);
      redis = Some (fun () -> `Error "cannot reach redis");
      openai = Some (fun () -> `Ok None);
    }
  in
  Health.Test_hooks.with_overrides overrides ~f:(fun () ->
      let summary =
        Health.Api.summary ~postgres:dummy_postgres ~config:sample_api_config ()
      in
      check_status "status" "degraded" summary;
      let json = Health.summary_to_yojson summary in
      let detail =
        json
        |> Yojson.Safe.Util.member "checks"
        |> Yojson.Safe.Util.to_list
        |> List.find_exn ~f:(fun entry ->
               String.equal
                 (Yojson.Safe.Util.member "name" entry
                 |> Yojson.Safe.Util.to_string)
                 "redis")
      in
      let status =
        Yojson.Safe.Util.member "status" detail |> Yojson.Safe.Util.to_string
      in
      check string "redis marked error" "error" status)

let test_api_error_on_postgres_failure () =
  let overrides =
    {
      Health.Test_hooks.empty with
      postgres = Some (fun () -> `Error "postgres offline");
      qdrant = Some (fun () -> `Ok None);
      redis = Some (fun () -> `Ok None);
      openai = Some (fun () -> `Ok None);
    }
  in
  Health.Test_hooks.with_overrides overrides ~f:(fun () ->
      let summary =
        Health.Api.summary ~postgres:dummy_postgres ~config:sample_api_config ()
      in
      check_status "status" "error" summary;
      let http_status = Health.http_status_of summary.Health.status in
      check bool "http mapped to 503" true
        (Cohttp.Code.code_of_status (http_status :> Cohttp.Code.status_code)
        = 503))

let test_worker_ok () =
  let overrides =
    {
      Health.Test_hooks.empty with
      postgres = Some (fun () -> `Ok None);
      qdrant = Some (fun () -> `Ok None);
      embeddings = Some (fun () -> `Ok (Some "endpoint"));
    }
  in
  let api_lazy = lazy (Ok sample_api_config) in
  Health.Test_hooks.with_overrides overrides ~f:(fun () ->
      let summary =
        Health.Worker.summary ~postgres:dummy_postgres
          ~config:sample_worker_config ~api_config:api_lazy ()
      in
      check_status "status" "ok" summary)

let test_worker_error_on_qdrant_failure () =
  let overrides =
    {
      Health.Test_hooks.empty with
      postgres = Some (fun () -> `Ok None);
      qdrant = Some (fun () -> `Error "qdrant down");
      embeddings = Some (fun () -> `Ok None);
    }
  in
  let api_lazy = lazy (Ok sample_api_config) in
  Health.Test_hooks.with_overrides overrides ~f:(fun () ->
      let summary =
        Health.Worker.summary ~postgres:dummy_postgres
          ~config:sample_worker_config ~api_config:api_lazy ()
      in
      check_status "status" "error" summary)

let suite =
  [
    test_case "api summary ok" `Quick test_api_ok;
    test_case "api summary degraded on redis failure" `Quick
      test_api_degraded_on_redis_failure;
    test_case "api summary error on postgres failure" `Quick
      test_api_error_on_postgres_failure;
    test_case "worker summary ok" `Quick test_worker_ok;
    test_case "worker error on qdrant failure" `Quick
      test_worker_error_on_qdrant_failure;
  ]
