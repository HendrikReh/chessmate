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
          match config.Config.Api.agent.cache with
          | Config.Api.Agent_cache.Redis _ -> ()
          | _ -> fail "expected redis cache"))

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
    test_case "api config fails when database missing" `Quick
      test_api_config_missing_database;
    test_case "worker config requires openai key" `Quick
      test_worker_config_missing_openai;
    test_case "cli guard limit parses" `Quick test_cli_guard_limit;
    test_case "cli guard limit disables" `Quick test_cli_guard_limit_disable;
    test_case "cli guard limit detects invalid" `Quick
      test_cli_guard_limit_invalid;
  ]
