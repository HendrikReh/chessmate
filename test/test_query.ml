open! Base
open Alcotest
open Chessmate

let to_filter_pairs filters =
  List.map filters ~f:(fun f -> f.Query_intent.field, f.Query_intent.value)

let test_query_intent_opening () =
  let request =
    { Query_intent.text =
        "Find top 3 King's Indian games where white is rated at least 2500 and black is 100 points lower"
    }
  in
  let plan = Query_intent.analyse request in
  check int "limit" 3 plan.Query_intent.limit;
  check (option int) "white min" (Some 2500) plan.Query_intent.rating.white_min;
  check (option int) "black min" None plan.Query_intent.rating.black_min;
  check (option int) "rating delta" (Some 100) plan.Query_intent.rating.max_rating_delta;
  let filters = to_filter_pairs plan.Query_intent.filters in
  let has_opening_filter =
    List.exists filters ~f:(fun (field, value) ->
        String.equal field "opening" && String.equal value "kings_indian_defense")
  in
  check bool "opening filter" true has_opening_filter;
  check bool "keyword includes indian" true (List.mem plan.Query_intent.keywords "indian" ~equal:String.equal)

let test_query_intent_draw () =
  let request = { Query_intent.text = "Show me five games that end in a draw in the French Defense endgame" } in
  let plan = Query_intent.analyse request in
  check int "limit fallback" 5 plan.Query_intent.limit;
  let filters = to_filter_pairs plan.Query_intent.filters in
  let expect_pairs =
    [ "opening", "french_defense";
      "phase", "endgame";
      "result", "1/2-1/2" ]
  in
  List.iter expect_pairs ~f:(fun expected ->
      let has_filter =
        List.mem filters expected ~equal:(fun (a1, b1) (a2, b2) -> String.equal a1 a2 && String.equal b1 b2)
      in
      check bool "expected filter present" true has_filter)

let sample_summary =
  { Repo_postgres.id = 1
  ; white = "Magnus Carlsen"
  ; black = "Viswanathan Anand"
  ; result = Some "1-0"
  ; event = Some "World Championship"
  ; opening_slug = Some "kings_indian_defense"
  ; opening_name = Some "King's Indian Defense"
  ; eco_code = Some "E94"
  ; white_rating = Some 2870
  ; black_rating = Some 2780
  ; played_on = Some "2014-11-11" }

let make_vector_points game_id score ~phases ~themes ~keywords =
  let payload =
    `Assoc
      [ "game_id", `Int game_id
      ; "phases", `List (List.map phases ~f:(fun phase -> `String phase))
      ; "themes", `List (List.map themes ~f:(fun theme -> `String theme))
      ; "keywords", `List (List.map keywords ~f:(fun kw -> `String kw))
      ]
  in
  [ { Repo_qdrant.id = Int.to_string game_id; score; payload = Some payload } ]

let test_hybrid_executor_merges_vector_hits () =
  let question =
    "Show me King's Indian games where white is rated at least 2800 and highlight middlegame tactics"
  in
  let plan = Query_intent.analyse { Query_intent.text = question } in
  let fetch_games _ = Or_error.return [ sample_summary ] in
  let vector_hits =
    make_vector_points sample_summary.Repo_postgres.id 0.92
      ~phases:[ "middlegame" ]
      ~themes:[ "tactics" ]
      ~keywords:[ "indian"; "attack" ]
    |> Hybrid_planner.vector_hits_of_points
  in
  let fetch_vectors _ = Or_error.return vector_hits in
  match Hybrid_executor.execute ~fetch_games ~fetch_vector_hits:fetch_vectors plan with
  | Error err -> failf "hybrid executor failed: %s" (Error.to_string_hum err)
  | Ok execution ->
      check int "result count" 1 (List.length execution.Hybrid_executor.results);
      check (list string) "warnings" [] execution.Hybrid_executor.warnings;
      let result = List.hd_exn execution.Hybrid_executor.results in
      check bool "phases merged" true (List.mem result.phases "middlegame" ~equal:String.equal);
      check bool "themes merged" true (List.mem result.themes "tactics" ~equal:String.equal);
      check bool "keywords merged" true (List.mem result.keywords "indian" ~equal:String.equal);
      check bool "vector score propagated" true Float.(abs (result.vector_score -. 0.92) < 1e-6)

let test_hybrid_executor_warns_on_vector_failure () =
  let plan =
    Query_intent.analyse
      { Query_intent.text = "Find King's Indian games with white above 2800 rating" }
  in
  let fetch_games _ = Or_error.return [ sample_summary ] in
  let fetch_vectors _ = Or_error.error_string "boom" in
  match Hybrid_executor.execute ~fetch_games ~fetch_vector_hits:fetch_vectors plan with
  | Error err -> failf "unexpected failure: %s" (Error.to_string_hum err)
  | Ok execution ->
      check bool "warnings emitted" true (not (List.is_empty execution.Hybrid_executor.warnings));
      let result = List.hd_exn execution.Hybrid_executor.results in
      check bool "fallback vector score" true Float.(result.vector_score > 0.0)

let test_hybrid_executor_with_agent () =
  let rating = { Query_intent.white_min = None; black_min = None; max_rating_delta = None } in
  let plan =
    { Query_intent.original = { Query_intent.text = "Agent evaluation test" }
    ; cleaned_text = "agent evaluation test"
    ; keywords = [ "agent"; "evaluation" ]
    ; filters = []
    ; rating
    ; limit = 5 }
  in
  let make_summary id name =
    { Repo_postgres.id = id
    ; white = name ^ " White"
    ; black = name ^ " Black"
    ; result = Some "1-0"
    ; event = Some "Test Event"
    ; opening_slug = Some "test_opening"
    ; opening_name = Some "Test Opening"
    ; eco_code = Some "C00"
    ; white_rating = Some 2600
    ; black_rating = Some 2550
    ; played_on = Some "2024-01-01" }
  in
  let summaries = [ make_summary 1 "Alpha"; make_summary 2 "Beta" ] in
  let fetch_games _ = Or_error.return summaries in
  let fetch_vectors _ = Or_error.return [] in
  let fetch_game_pgns ids =
    let pgn = "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 1-0" in
    Or_error.return (List.map ids ~f:(fun id -> id, pgn))
  in
  let agent_evaluator ~plan:_ ~candidates =
    let open Agent_evaluator in
    let evals =
      candidates
      |> List.map ~f:(fun (summary, _) ->
             if Int.equal summary.Repo_postgres.id 2 then
               { game_id = summary.Repo_postgres.id
               ; score = 0.9
               ; explanation = Some "Strong kingside attack"
               ; themes = [ "attack" ]
               ; reasoning_effort = Agents_gpt5_client.Effort.High
               ; usage = None }
             else
               { game_id = summary.Repo_postgres.id
               ; score = 0.2
               ; explanation = Some "Only loosely related"
               ; themes = []
               ; reasoning_effort = Agents_gpt5_client.Effort.Medium
               ; usage = None })
    in
    Or_error.return evals
  in
  match
    Hybrid_executor.execute
      ~fetch_games
      ~fetch_vector_hits:fetch_vectors
      ~fetch_game_pgns
      ~agent_evaluator
      plan
  with
  | Error err -> failf "agent execution failed: %s" (Error.to_string_hum err)
  | Ok execution ->
      let results = execution.Hybrid_executor.results in
      check int "result count" 2 (List.length results);
      let first = List.hd_exn results in
      let second = List.nth_exn results 1 in
      check int "top game id" 2 first.summary.Repo_postgres.id;
      (match first.agent_score with
      | Some score -> check bool "agent score recorded" true Float.(abs (score -. 0.9) < 1e-6)
      | None -> fail "missing agent score");
      check bool "agent explanation present" true (Option.is_some first.agent_explanation);
      check bool "agent themes propagated" true (List.mem first.agent_themes "attack" ~equal:String.equal);
      check bool "final ranking" true Float.(first.total_score > second.total_score)

let suite =
  [ "query intent opening", `Quick, test_query_intent_opening;
    "query intent draw", `Quick, test_query_intent_draw;
    "hybrid executor merges vector hits", `Quick, test_hybrid_executor_merges_vector_hits;
    "hybrid executor warns on vector failure", `Quick, test_hybrid_executor_warns_on_vector_failure;
    "hybrid executor integrates agent", `Quick, test_hybrid_executor_with_agent
  ]
