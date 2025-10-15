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

let set_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_env overrides f =
  let saved =
    List.map overrides ~f:(fun (name, _) -> (name, Stdlib.Sys.getenv_opt name))
  in
  List.iter overrides ~f:(fun (name, value) -> set_env name value);
  Exn.protect ~f ~finally:(fun () ->
      List.iter saved ~f:(fun (name, value) -> set_env name value))

let test_api_config_success () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://user:pass@localhost:5432/db");
      ("QDRANT_URL", Some "http://localhost:6333");
      ("CHESSMATE_API_PORT", Some "9090");
      ("AGENT_API_KEY", Some "test-agent");
      ("AGENT_MODEL", Some "gpt-5");
      ("AGENT_REASONING_EFFORT", Some "low");
      ("AGENT_VERBOSITY", Some "medium");
      ("AGENT_REQUEST_TIMEOUT_SECONDS", Some "12.5");
      ("AGENT_CACHE_REDIS_URL", Some "redis://localhost:6379");
      ("AGENT_CACHE_REDIS_NAMESPACE", Some "chessmate:test:");
      ("AGENT_CACHE_TTL_SECONDS", Some "120");
    ]
    (fun () ->
      match Config.Api.load () with
      | Error err ->
          failf "unexpected config failure: %s" (Error.to_string_hum err)
      | Ok config -> (
          check string "database" "postgres://user:pass@localhost:5432/db"
            config.Config.Api.database_url;
          check string "qdrant" "http://localhost:6333"
            config.Config.Api.qdrant_url;
          check int "port" 9090 config.Config.Api.port;
          (match config.Config.Api.agent.reasoning_effort with
          | Agents_gpt5_client.Effort.Low -> ()
          | other ->
              failf "expected low effort, got %s"
                (Agents_gpt5_client.Effort.to_string other));
          check bool "agent timeout" true
            Float.(
              abs (config.Config.Api.agent.request_timeout_seconds -. 12.5)
              < 1e-6);
          check int "default candidate multiplier" 5
            config.Config.Api.agent.candidate_multiplier;
          check int "default candidate max" 25
            config.Config.Api.agent.candidate_max;
          check int "breaker threshold" 5
            config.Config.Api.agent.circuit_breaker_threshold;
          check bool "breaker cooloff default"
            Float.(
              abs
                (config.Config.Api.agent.circuit_breaker_cooloff_seconds -. 60.)
              < 1e-6);
          match config.Config.Api.agent.cache with
          | Config.Api.Agent_cache.Redis _ -> ()
          | _ -> fail "expected redis cache"))

let test_api_config_candidate_limits_override () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://user:pass@localhost:5432/db");
      ("QDRANT_URL", Some "http://localhost:6333");
      ("AGENT_CANDIDATE_MULTIPLIER", Some "3");
      ("AGENT_CANDIDATE_MAX", Some "40");
      ("AGENT_CIRCUIT_BREAKER_THRESHOLD", Some "7");
      ("AGENT_CIRCUIT_BREAKER_COOLOFF_SECONDS", Some "120");
    ]
    (fun () ->
      match Config.Api.load () with
      | Error err ->
          failf "unexpected config failure: %s" (Error.to_string_hum err)
      | Ok config ->
          check int "candidate multiplier" 3
            config.Config.Api.agent.candidate_multiplier;
          check int "candidate max" 40 config.Config.Api.agent.candidate_max;
          check int "breaker threshold override" 7
            config.Config.Api.agent.circuit_breaker_threshold;
          check bool "breaker cooloff override"
            Float.(
              abs
                (config.Config.Api.agent.circuit_breaker_cooloff_seconds -. 120.)
              < 1e-6))

let test_api_config_missing_database () =
  with_env
    [ ("DATABASE_URL", None); ("QDRANT_URL", Some "http://localhost:6333") ]
    (fun () ->
      match Config.Api.load () with
      | Ok _ -> fail "expected configuration failure"
      | Error err ->
          check bool "mentions DATABASE_URL" true
            (String.is_substring (Error.to_string_hum err)
               ~substring:"DATABASE_URL"))

let test_worker_config_missing_openai () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://localhost/db"); ("OPENAI_API_KEY", None);
    ]
    (fun () ->
      match Config.Worker.load () with
      | Ok _ -> fail "expected worker config failure"
      | Error err ->
          check bool "mentions OPENAI_API_KEY" true
            (String.is_substring (Error.to_string_hum err)
               ~substring:"OPENAI_API_KEY"))

let test_worker_config_batch_size_defaults () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://localhost/db");
      ("OPENAI_API_KEY", Some "abc");
      ("CHESSMATE_WORKER_BATCH_SIZE", None);
    ]
    (fun () ->
      match Config.Worker.load () with
      | Error err ->
          failf "unexpected worker config failure: %s" (Error.to_string_hum err)
      | Ok config ->
          check int "default batch size" 16 config.batch_size;
          check int "default health port" 8081 config.health_port)

let test_worker_config_batch_size_override () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://localhost/db");
      ("OPENAI_API_KEY", Some "abc");
      ("CHESSMATE_WORKER_BATCH_SIZE", Some "32");
    ]
    (fun () ->
      match Config.Worker.load () with
      | Error err ->
          failf "unexpected worker config failure: %s" (Error.to_string_hum err)
      | Ok config ->
          check int "override batch size" 32 config.batch_size;
          check int "default health port" 8081 config.health_port)

let test_worker_config_health_port_override () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://localhost/db");
      ("OPENAI_API_KEY", Some "abc");
      ("CHESSMATE_WORKER_HEALTH_PORT", Some "9090");
    ]
    (fun () ->
      match Config.Worker.load () with
      | Error err ->
          failf "unexpected worker config failure: %s" (Error.to_string_hum err)
      | Ok config -> check int "override health port" 9090 config.health_port)

let test_worker_config_health_port_invalid () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://localhost/db");
      ("OPENAI_API_KEY", Some "abc");
      ("CHESSMATE_WORKER_HEALTH_PORT", Some "0");
    ]
    (fun () ->
      match Config.Worker.load () with
      | Ok _ -> fail "expected health port validation failure"
      | Error err ->
          check bool "mentions env" true
            (String.is_substring (Error.to_string_hum err)
               ~substring:"CHESSMATE_WORKER_HEALTH_PORT"))

let test_worker_config_batch_size_invalid () =
  with_env
    [
      ("DATABASE_URL", Some "postgres://localhost/db");
      ("OPENAI_API_KEY", Some "abc");
      ("CHESSMATE_WORKER_BATCH_SIZE", Some "0");
    ]
    (fun () ->
      match Config.Worker.load () with
      | Ok _ -> fail "expected batch size validation failure"
      | Error err ->
          check bool "mentions env" true
            (String.is_substring (Error.to_string_hum err)
               ~substring:"CHESSMATE_WORKER_BATCH_SIZE"))

let test_cli_guard_limit () =
  with_env
    [ ("CHESSMATE_MAX_PENDING_EMBEDDINGS", Some "500000") ]
    (fun () ->
      match Config.Cli.pending_guard_limit ~default:250_000 with
      | Ok (Some value) -> check int "limit" 500_000 value
      | Ok None -> fail "expected explicit limit"
      | Error err ->
          failf "unexpected guard failure: %s" (Error.to_string_hum err))

let test_cli_guard_limit_disable () =
  with_env
    [ ("CHESSMATE_MAX_PENDING_EMBEDDINGS", Some "0") ]
    (fun () ->
      match Config.Cli.pending_guard_limit ~default:250_000 with
      | Ok (Some _) -> fail "expected guard to disable"
      | Ok None -> ()
      | Error err ->
          failf "unexpected guard failure: %s" (Error.to_string_hum err))

let test_cli_guard_limit_invalid () =
  with_env
    [ ("CHESSMATE_MAX_PENDING_EMBEDDINGS", Some "not-an-int") ]
    (fun () ->
      match Config.Cli.pending_guard_limit ~default:250_000 with
      | Error err ->
          check bool "mentions guard env" true
            (String.is_substring (Error.to_string_hum err)
               ~substring:"CHESSMATE_MAX_PENDING_EMBEDDINGS")
      | Ok _ -> fail "expected guard parsing failure")

let suite =
  [
    test_case "api config loads" `Quick test_api_config_success;
    test_case "api candidate limits configurable" `Quick
      test_api_config_candidate_limits_override;
    test_case "api config fails when database missing" `Quick
      test_api_config_missing_database;
    test_case "worker config requires openai key" `Quick
      test_worker_config_missing_openai;
    test_case "worker config batch size defaults" `Quick
      test_worker_config_batch_size_defaults;
    test_case "worker config batch size override" `Quick
      test_worker_config_batch_size_override;
    test_case "worker config batch size invalid" `Quick
      test_worker_config_batch_size_invalid;
    test_case "cli guard limit parses" `Quick test_cli_guard_limit;
    test_case "cli guard limit disables" `Quick test_cli_guard_limit_disable;
    test_case "cli guard limit detects invalid" `Quick
      test_cli_guard_limit_invalid;
  ]
