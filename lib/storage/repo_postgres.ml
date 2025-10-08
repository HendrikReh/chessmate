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

(* Postgres repository for ingesting games, managing jobs, and fetching query data. *)

open! Base
open Stdio

let ( let* ) t f = Or_error.bind t ~f
let ( let+ ) t f = Or_error.map t ~f

module Job = Embedding_job
module Metadata = Game_metadata

type game_summary = {
  id : int;
  white : string;
  black : string;
  result : string option;
  event : string option;
  opening_slug : string option;
  opening_name : string option;
  eco_code : string option;
  white_rating : int option;
  black_rating : int option;
  played_on : string option;
}

let option_of_string s =
  let trimmed = String.strip s in
  if String.is_empty trimmed then None else Some trimmed

let int_option_of_string s = Option.bind (option_of_string s) ~f:Int.of_string_opt

let normalize_eco_code s = String.uppercase (String.strip s)

let eco_filter value =
  let value = normalize_eco_code value in
  match String.split value ~on:'-' with
  | [ start_code; end_code ] when not (String.is_empty start_code) && not (String.is_empty end_code) ->
      `Range (start_code, end_code)
  | _ -> `Exact value

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
        let field_separator = "\t" in
        let command =
          Printf.sprintf
            "psql --no-psqlrc -X -q -t -A -F \"%s\" --dbname=%s -v ON_ERROR_STOP=1 -f %s"
            field_separator
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
      "INSERT INTO games\n       (white_player_id, black_player_id, event, site, round, played_on, eco_code, opening_name, opening_slug, result, white_rating, black_rating, pgn)\n       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id;"
      (sql_int_opt white_id)
      (sql_int_opt black_id)
      (sql_string_opt metadata.event)
      (sql_string_opt metadata.site)
      (sql_string_opt metadata.round)
      (sql_string_opt metadata.date)
      (sql_string_opt metadata.eco_code)
      (sql_string_opt metadata.opening_name)
      (sql_string_opt metadata.opening_slug)
      (sql_string_opt metadata.result)
      (sql_int_opt metadata.white.rating)
      (sql_int_opt metadata.black.rating)
      (sql_string pgn)
  in
  let* game_id = insert_single_row repo sql in
  let+ inserted = insert_positions repo game_id moves 0 in
  (game_id, inserted)

let parse_game_row line =
  match String.split line ~on:'\t' with
  | [ id_str
    ; white
    ; black
    ; result
    ; event
    ; opening_slug
    ; opening_name
    ; eco_code
    ; white_rating
    ; black_rating
    ; played_on ] ->
      (match Int.of_string_opt id_str with
      | None -> Or_error.errorf "Invalid game id: %s" id_str
      | Some id ->
          Or_error.return
            { id
            ; white = if String.is_empty white then "Unknown" else white
            ; black = if String.is_empty black then "Unknown" else black
            ; result = option_of_string result
            ; event = option_of_string event
            ; opening_slug = option_of_string opening_slug
            ; opening_name = option_of_string opening_name
            ; eco_code = option_of_string eco_code
            ; white_rating = int_option_of_string white_rating
            ; black_rating = int_option_of_string black_rating
            ; played_on = option_of_string played_on
            })
  | _ -> Or_error.errorf "Unexpected game row: %s" line

let build_conditions ~filters ~rating =
  let conditions = ref [] in
  List.iter filters ~f:(fun (filter : Query_intent.metadata_filter) ->
      match String.lowercase filter.field with
      | "opening" -> conditions := Printf.sprintf "g.opening_slug = %s" (sql_string filter.value) :: !conditions
      | "result" -> conditions := Printf.sprintf "g.result = %s" (sql_string filter.value) :: !conditions
      | "eco_range" ->
          (match eco_filter filter.value with
          | `Range (start_code, end_code) ->
              conditions :=
                Printf.sprintf "g.eco_code >= %s AND g.eco_code <= %s" (sql_string start_code) (sql_string end_code)
                :: !conditions
          | `Exact single -> conditions := Printf.sprintf "g.eco_code = %s" (sql_string single) :: !conditions)
      | _ -> ());
  (match rating.Query_intent.white_min with
  | Some min -> conditions := Printf.sprintf "g.white_rating >= %d" min :: !conditions
  | None -> ());
  (match rating.Query_intent.black_min with
  | Some min -> conditions := Printf.sprintf "g.black_rating >= %d" min :: !conditions
  | None -> ());
  (match rating.Query_intent.max_rating_delta with
  | Some delta ->
      conditions :=
        Printf.sprintf
          "g.white_rating IS NOT NULL AND g.black_rating IS NOT NULL AND ABS(g.white_rating - g.black_rating) <= %d"
          delta
        :: !conditions
  | None -> ());
  !conditions

let search_games repo ~filters ~rating ~limit =
  let limit = Int.max 1 limit in
  let conditions = build_conditions ~filters ~rating in
  let where_clause =
    if List.is_empty conditions then ""
    else "WHERE " ^ String.concat ~sep:" AND " (List.rev conditions)
  in
  let sql =
    Printf.sprintf
      "SELECT g.id,\n              COALESCE(w.name, ''),\n              COALESCE(b.name, ''),\n              COALESCE(g.result, ''),\n              COALESCE(g.event, ''),\n              COALESCE(g.opening_slug, ''),\n              COALESCE(g.opening_name, ''),\n              COALESCE(g.eco_code, ''),\n              COALESCE(CAST(g.white_rating AS TEXT), ''),\n              COALESCE(CAST(g.black_rating AS TEXT), ''),\n              COALESCE(CAST(g.played_on AS TEXT), '')\n       FROM games g\n       LEFT JOIN players w ON g.white_player_id = w.id\n       LEFT JOIN players b ON g.black_player_id = b.id\n       %s\n       ORDER BY g.played_on DESC NULLS LAST, g.id DESC\n       LIMIT %d;"
      where_clause
      limit
  in
  let* rows = run_psql repo sql in
  rows |> List.map ~f:parse_game_row |> Or_error.all

let fetch_games_with_pgn repo ~ids =
  let unique_ids =
    ids
    |> List.dedup_and_sort ~compare:Int.compare
  in
  match unique_ids with
  | [] -> Or_error.return []
  | _ ->
      let id_list =
        unique_ids
        |> List.map ~f:Int.to_string
        |> String.concat ~sep:","
      in
      let sql =
        Printf.sprintf
          "SELECT json_build_object('id', id, 'pgn', pgn)::text FROM games WHERE id IN (%s);"
          id_list
      in
      let* rows = run_psql repo sql in
      rows
      |> List.map ~f:(fun line ->
             match Or_error.try_with (fun () -> Yojson.Safe.from_string line) with
             | Error err -> Or_error.errorf "Malformed game pgn row (json): %s (%s)" line (Error.to_string_hum err)
             | Ok json -> (
                 let open Yojson.Safe.Util in
                 match member "id" json |> to_int_option, member "pgn" json |> to_string_option with
                 | Some id, Some pgn -> Or_error.return (id, pgn)
                 | _ -> Or_error.errorf "Malformed game pgn row: %s" line))
      |> Or_error.all

let parse_job_row line =
  let parse_int field value =
    Or_error.try_with (fun () -> Int.of_string value)
    |> Or_error.tag ~tag:(Printf.sprintf "Invalid integer for %s" field)
  in
  match String.split line ~on:'\t' with
  | id_str :: fen :: attempts_str :: status_str :: rest ->
      let last_error_str = String.concat ~sep:"\t" rest in
      let last_error = if String.is_empty last_error_str then None else Some last_error_str in
      let* id = parse_int "id" id_str in
      let* attempts = parse_int "attempts" attempts_str in
      let* status = Job.status_of_string status_str in
      Or_error.return { Job.id; fen; attempts; status; last_error }
  | _ -> Or_error.errorf "Malformed job row: %s" line

let pending_embedding_job_count repo =
  let sql = "SELECT COUNT(*) FROM embedding_jobs WHERE status = 'pending';" in
  let* count = query_single_int repo sql in
  match count with
  | Some value -> Or_error.return value
  | None -> Or_error.return 0

let claim_pending_jobs repo ~limit =
  if Int.(limit <= 0) then Or_error.return []
  else
    let sql =
      Printf.sprintf
        "WITH candidate AS (\n         SELECT id\n         FROM embedding_jobs\n         WHERE status = 'pending'\n         ORDER BY enqueued_at ASC\n         FOR UPDATE SKIP LOCKED\n         LIMIT %d\n       )\n       UPDATE embedding_jobs AS ej\n       SET status = 'in_progress', attempts = ej.attempts + 1, started_at = NOW(), last_error = NULL\n       WHERE ej.id IN (SELECT id FROM candidate)\n       RETURNING ej.id, ej.fen, ej.attempts, ej.status, COALESCE(ej.last_error, '');"
        limit
    in
    let* rows = run_psql repo sql in
    rows
    |> List.map ~f:parse_job_row
    |> Or_error.all

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
