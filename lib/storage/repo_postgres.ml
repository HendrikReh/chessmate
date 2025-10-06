open! Base
open Stdio

let ( let* ) t f = Or_error.bind t ~f
let ( let+ ) t f = Or_error.map t ~f

module Job = Embedding_job
module Metadata = Game_metadata

(* Connection string wrapper delegating to the local [psql] client. *)
type t = { conninfo : string }

let create conninfo =
  if String.is_empty (String.strip conninfo) then
    Or_error.error_string "Postgres connection string cannot be empty"
  else
    Or_error.return { conninfo }

let escape_literal s = String.substr_replace_all s ~pattern:"'" ~with_:"''"

let sql_string s = Printf.sprintf "'%s'" (escape_literal s)

let sql_string_opt = function
  | None -> "NULL"
  | Some s -> sql_string s

let sql_int_opt = function
  | None -> "NULL"
  | Some i -> Int.to_string i

let run_psql t sql =
  let script = Stdlib.Filename.temp_file "chessmate_sql" ".sql" in
  Exn.protect
    ~f:(fun () ->
        Out_channel.write_all script ~data:sql;
        let command =
          Printf.sprintf
            "psql --no-psqlrc -X -q -t -A -F '\\t' --dbname=%s -v ON_ERROR_STOP=1 -f %s"
            (Stdlib.Filename.quote t.conninfo)
            (Stdlib.Filename.quote script)
        in
        let ic, oc, ec = Unix.open_process_full command (Unix.environment ()) in
        Out_channel.close oc;
        let stdout = In_channel.input_all ic in
        let stderr = In_channel.input_all ec in
        match Unix.close_process_full (ic, oc, ec) with
        | Unix.WEXITED 0 ->
            stdout
            |> String.split_lines
            |> List.map ~f:String.strip
            |> List.filter ~f:(Fn.non String.is_empty)
            |> Or_error.return
        | Unix.WEXITED code ->
            Or_error.errorf "psql exited with code %d: %s" code (String.strip stderr)
        | Unix.WSIGNALED signal ->
            Or_error.errorf "psql terminated by signal %d" signal
        | Unix.WSTOPPED signal ->
            Or_error.errorf "psql stopped by signal %d" signal)
    ~finally:(fun () -> try Stdlib.Sys.remove script with _ -> ())

let exec t sql =
  let* _ = run_psql t sql in
  Or_error.return ()

let query_single_int t sql =
  let* rows = run_psql t sql in
  match rows with
  | [] -> Or_error.return None
  | value :: _ -> (
      match Int.of_string value with
      | id -> Or_error.return (Some id)
      | exception _ -> Or_error.errorf "Expected integer result, got %s" value)

let insert_single_row t sql =
  let* rows = run_psql t sql in
  match rows with
  | value :: _ -> (
      match Int.of_string value with
      | id -> Or_error.return id
      | exception _ -> Or_error.errorf "Expected integer result, got %s" value)
  | [] -> Or_error.error_string "Query returned no rows"

let select_player_by_fide t fide_id =
  let sql =
    Printf.sprintf
      "SELECT id FROM players WHERE fide_id = %s LIMIT 1;"
      (sql_string fide_id)
  in
  query_single_int t sql

let select_player_by_name t name =
  let sql =
    Printf.sprintf "SELECT id FROM players WHERE name = %s LIMIT 1;" (sql_string name)
  in
  query_single_int t sql

let insert_player t (player : Metadata.player) =
  let sql =
    Printf.sprintf
      "INSERT INTO players (name, fide_id, rating_peak) VALUES (%s, %s, %s) RETURNING id;"
      (sql_string player.name)
      (sql_string_opt player.fide_id)
      (sql_int_opt player.rating)
  in
  insert_single_row t sql

let upsert_player t (player : Metadata.player) =
  let name = String.strip player.name in
  if String.is_empty name then Or_error.return None
  else
    let* by_fide =
      match player.fide_id with
      | Some fid when not (String.is_empty (String.strip fid)) -> select_player_by_fide t fid
      | _ -> Or_error.return None
    in
    match by_fide with
    | Some id -> Or_error.return (Some id)
    | None ->
        let* existing = select_player_by_name t name in
        (match existing with
        | Some id -> Or_error.return (Some id)
        | None ->
            let+ id = insert_player t { player with name } in
            Some id)

let placeholder_fen san = Printf.sprintf "SAN:%s" san

let side_to_move ply = if Int.(ply % 2 = 1) then "black" else "white"

let insert_position t game_id (move : Pgn_parser.move) =
  let fen = placeholder_fen move.san in
  let side = side_to_move move.ply in
  let move_number_literal =
    if Int.(move.turn <= 0) then "NULL" else Int.to_string move.turn
  in
  let sql =
    Printf.sprintf
      "WITH inserted AS (\n\
       INSERT INTO positions (game_id, ply, move_number, side_to_move, fen, san)\n\
       VALUES (%d, %d, %s, %s, %s, %s) RETURNING id, fen)\n\
       INSERT INTO embedding_jobs (position_id, fen)\n\
       SELECT id, fen FROM inserted;"
      game_id
      move.ply
      move_number_literal
      (sql_string side)
      (sql_string fen)
      (sql_string move.san)
  in
  exec t sql

let rec insert_positions t game_id moves count =
  match moves with
  | [] -> Or_error.return count
  | move :: rest ->
      let* () = insert_position t game_id move in
      insert_positions t game_id rest (count + 1)

let insert_game (repo : t) ~metadata ~pgn ~moves =
  let* white_id = upsert_player repo metadata.Metadata.white in
  let* black_id = upsert_player repo metadata.Metadata.black in
  let sql =
    Printf.sprintf
      "INSERT INTO games\n       (white_player_id, black_player_id, event, site, round, played_on, eco_code, result, white_rating, black_rating, pgn)\n       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id;"
      (sql_int_opt white_id)
      (sql_int_opt black_id)
      (sql_string_opt metadata.event)
      (sql_string_opt metadata.site)
      (sql_string_opt metadata.round)
      (sql_string_opt metadata.date)
      (sql_string_opt metadata.eco_code)
      (sql_string_opt metadata.result)
      (sql_int_opt metadata.white.rating)
      (sql_int_opt metadata.black.rating)
      (sql_string pgn)
  in
  let* game_id = insert_single_row repo sql in
  let+ inserted = insert_positions repo game_id moves 0 in
  (game_id, inserted)

let parse_job_row line =
  let parts = String.split ~on:'\t' line in
  match parts with
  | [ id_str; fen; attempts_str; status_str; last_error_str ] ->
      let parse_int field value =
        Or_error.try_with (fun () -> Int.of_string value)
        |> Or_error.tag ~tag:(Printf.sprintf "Invalid integer for %s" field)
      in
      let last_error = if String.is_empty last_error_str then None else Some last_error_str in
      let* id = parse_int "id" id_str in
      let* attempts = parse_int "attempts" attempts_str in
      let* status = Job.status_of_string status_str in
      Or_error.return { Job.id; fen; attempts; status; last_error }
  | _ -> Or_error.errorf "Malformed job row: %s" line

let fetch_pending_jobs repo ~limit =
  let sql =
    Printf.sprintf
      "SELECT id, fen, attempts, status, COALESCE(last_error, '')\n       FROM embedding_jobs\n       WHERE status = 'pending'\n       ORDER BY enqueued_at ASC\n       LIMIT %d;"
      limit
  in
  let* rows = run_psql repo sql in
  rows
  |> List.map ~f:parse_job_row
  |> Or_error.all

let mark_job_started repo ~job_id =
  let sql =
    Printf.sprintf
      "UPDATE embedding_jobs\n       SET status = 'in_progress', attempts = attempts + 1, started_at = NOW(), last_error = NULL\n       WHERE id = %d;"
      job_id
  in
  exec repo sql

let mark_job_completed repo ~job_id ~vector_id =
  let vector_literal =
    if String.is_empty (String.strip vector_id) then "NULL" else sql_string vector_id
  in
  let sql =
    Printf.sprintf
      "WITH updated AS (\n       UPDATE embedding_jobs\n       SET status = 'completed', completed_at = NOW(), last_error = NULL\n       WHERE id = %d\n       RETURNING position_id)\n       UPDATE positions\n       SET vector_id = %s\n       WHERE id IN (SELECT position_id FROM updated);"
      job_id
      vector_literal
  in
  exec repo sql

let mark_job_failed repo ~job_id ~error =
  let sql =
    Printf.sprintf
      "UPDATE embedding_jobs\n       SET status = 'failed', last_error = %s, completed_at = NULL\n       WHERE id = %d;"
      (sql_string error)
      job_id
  in
  exec repo sql
