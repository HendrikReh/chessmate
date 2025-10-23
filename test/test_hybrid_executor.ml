open! Base
open Alcotest
open Chessmate

let sample_summary id : Repo_postgres.game_summary =
  {
    Repo_postgres.id;
    white = "Test White";
    black = "Test Black";
    result = Some "1-0";
    event = Some "Test Event";
    opening_slug = Some "test_opening";
    opening_name = Some "Test Opening";
    eco_code = Some "A00";
    white_rating = Some 2500;
    black_rating = Some 2400;
    played_on = Some "2025-01-01";
  }

let test_skip_when_circuit_open () =
  let breaker = Agent_circuit_breaker.create () in
  Agent_circuit_breaker.configure breaker ~threshold:1 ~cooloff_seconds:60.;
  Agent_circuit_breaker.record_failure breaker;
  let fetch_games _plan =
    Or_error.return Repo_postgres.{ games = [ sample_summary 1 ]; total = 1 }
  in
  let fetch_vector_hits _plan = Or_error.return ([], []) in
  let fetch_game_pgns _ids = Or_error.return [ (1, "1. e4 e5 2. Nf3 Nc6") ] in
  let evaluator_called = ref 0 in
  let agent_evaluator ~plan:_ ~candidates:_ =
    Int.incr evaluator_called;
    Or_error.return []
  in
  let plan : Query_intent.plan =
    Query_intent.
      {
        original = { text = "test"; limit = None; offset = None };
        cleaned_text = "test";
        keywords = [];
        filters = [];
        rating =
          {
            Query_intent.white_min = None;
            black_min = None;
            max_rating_delta = None;
          };
        limit = 1;
        offset = 0;
      }
  in
  match
    Hybrid_executor.execute ~fetch_games ~fetch_vector_hits ~fetch_game_pgns
      ~agent_evaluator ~agent_candidate_multiplier:1 ~agent_candidate_max:1
      ~agent_timeout_seconds:5. ~agent_circuit_breaker:breaker plan
  with
  | Error err -> failf "hybrid executor failed: %s" (Error.to_string_hum err)
  | Ok execution ->
      check bool "agent evaluator skipped" true Int.(!evaluator_called = 0);
      check string "status circuit open" "circuit_open"
        (Hybrid_executor.agent_status_to_string
           execution.Hybrid_executor.agent_status);
      let circuit_warning_present =
        List.exists execution.Hybrid_executor.warnings ~f:(fun warning ->
            String.is_substring warning ~substring:"circuit breaker")
      in
      check bool "warning emitted" true circuit_warning_present

let suite =
  [
    ( "hybrid executor skips agent when breaker open",
      `Quick,
      test_skip_when_circuit_open );
  ]
