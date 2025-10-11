open! Base
open Alcotest
open Chessmate
module Support = Test_integration_support
module Job = Embedding_job

let ( let* ) t f = Or_error.bind t ~f
let ( let+ ) t f = Or_error.map t ~f

let expect_ok label result =
  match result with
  | Ok value -> value
  | Error err -> failf "%s: %s" label (Error.to_string_hum err)

let ingest_fixture env filename =
  let path = Support.fixture_path filename in
  Ingest_command.run path
  |> Or_error.tag ~tag:"ingest command failed"
  |> Or_error.map ~f:(fun () -> env)

let test_ingest_workflow () =
  match Support.fetch_template () with
  | None ->
      Stdio.eprintf "[integration] %s\n%!" Support.missing_template_message
  | Some template ->
      let result =
        Support.with_initialized_database ~template ~f:(fun env ->
            let* (_ : Support.env) = ingest_fixture env "sample_game.pgn" in
            let* games = Support.scalar_int env "SELECT COUNT(*) FROM games;" in
            let* positions =
              Support.scalar_int env "SELECT COUNT(*) FROM positions;"
            in
            let* embedding_jobs =
              Support.scalar_int env
                "SELECT COUNT(*) FROM embedding_jobs WHERE status = 'pending';"
            in
            let* players =
              Support.scalar_int env "SELECT COUNT(*) FROM players;"
            in
            Or_error.return (games, positions, embedding_jobs, players))
      in
      let games, positions, jobs, players =
        expect_ok "ingest workflow" result
      in
      check int "games" 1 games;
      check int "players" 2 players;
      check int "positions" 6 positions;
      check int "pending jobs" 6 jobs

let test_embedding_job_lifecycle () =
  match Support.fetch_template () with
  | None ->
      Stdio.eprintf "[integration] %s\n%!" Support.missing_template_message
  | Some template ->
      let result =
        Support.with_initialized_database ~template ~f:(fun env ->
            let* (_ : Support.env) = ingest_fixture env "sample_game.pgn" in
            let* repo = Repo_postgres.create env.Support.database_url in
            let* jobs = Repo_postgres.claim_pending_jobs repo ~limit:16 in
            let* () =
              jobs
              |> List.map ~f:(fun job ->
                     Repo_postgres.mark_job_completed repo ~job_id:job.Job.id
                       ~vector_id:"vec:test")
              |> Or_error.all_unit
            in
            let* completed =
              Support.scalar_int env
                "SELECT COUNT(*) FROM embedding_jobs WHERE status = \
                 'completed';"
            in
            let* pending =
              Support.scalar_int env
                "SELECT COUNT(*) FROM embedding_jobs WHERE status = 'pending';"
            in
            let* vectorized =
              Support.scalar_int env
                "SELECT COUNT(*) FROM positions WHERE vector_id IS NOT NULL;"
            in
            Or_error.return (List.length jobs, completed, pending, vectorized))
      in
      let claimed, completed, pending, vectorized =
        expect_ok "embedding job lifecycle" result
      in
      check int "claimed jobs" 6 claimed;
      check int "completed jobs" 6 completed;
      check int "pending jobs" 0 pending;
      check int "vectorized positions" 6 vectorized

let test_hybrid_executor_pipeline () =
  match Support.fetch_template () with
  | None ->
      Stdio.eprintf "[integration] %s\n%!" Support.missing_template_message
  | Some template ->
      let result =
        Support.with_initialized_database ~template ~f:(fun env ->
            let* (_ : Support.env) = ingest_fixture env "sample_game.pgn" in
            let* repo = Repo_postgres.create env.Support.database_url in
            let* row =
              Support.fetch_row env
                "SELECT id::text FROM games ORDER BY id LIMIT 1;"
            in
            let* game_id =
              match row with
              | Some id_str :: _ -> (
                  match Int.of_string_opt id_str with
                  | Some value -> Or_error.return value
                  | None -> Or_error.errorf "Invalid game id value: %s" id_str)
              | _ -> Or_error.error_string "No ingested games found"
            in
            let plan =
              Query_intent.analyse
                { Query_intent.text = "Find sample games with e4" }
            in
            let fetch_games plan =
              Repo_postgres.search_games repo ~filters:plan.Query_intent.filters
                ~rating:plan.rating ~limit:plan.limit
            in
            let vector_hit =
              {
                Hybrid_planner.game_id;
                score = 0.92;
                phases = [ "middlegame" ];
                themes = [ "attack" ];
                keywords = [ "sample"; "attack" ];
              }
            in
            let fetch_vector_hits (_ : Query_intent.plan) =
              Or_error.return [ vector_hit ]
            in
            let* execution =
              Hybrid_executor.execute ~fetch_games ~fetch_vector_hits plan
            in
            Or_error.return (execution, game_id))
      in
      let execution, expected_id =
        expect_ok "hybrid executor pipeline" result
      in
      check int "warnings" 0 (List.length execution.Hybrid_executor.warnings);
      let results = execution.Hybrid_executor.results in
      check int "result count" 1 (List.length results);
      let top = List.hd_exn results in
      let summary = top.Hybrid_executor.summary in
      check int "result id" expected_id summary.Repo_postgres.id;
      check bool "vector score" true
        Float.(top.Hybrid_executor.vector_score > 0.8);
      check bool "themes include attack" true
        (List.mem top.Hybrid_executor.themes "attack" ~equal:String.equal)

let suite =
  [
    test_case "ingest workflow persists data" `Slow test_ingest_workflow;
    test_case "embedding job lifecycle completes" `Slow
      test_embedding_job_lifecycle;
    test_case "hybrid executor surfaces ingested game" `Slow
      test_hybrid_executor_pipeline;
  ]
