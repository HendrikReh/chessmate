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

let ( let* ) t f = Or_error.bind t ~f
let ( let+ ) t f = Or_error.map t ~f

module Job = Embedding_job
module Metadata = Game_metadata
module Pg = Postgresql

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

type t = {
  conn : Pg.connection;
  mutex : Stdlib.Mutex.t;
}

let string_of_status = function
  | Pg.Empty_query -> "empty_query"
  | Pg.Command_ok -> "command_ok"
  | Pg.Tuples_ok -> "tuples_ok"
  | Pg.Copy_out -> "copy_out"
  | Pg.Copy_in -> "copy_in"
  | Pg.Bad_response -> "bad_response"
  | Pg.Nonfatal_error -> "nonfatal_error"
  | Pg.Fatal_error -> "fatal_error"
  | Pg.Copy_both -> "copy_both"
  | Pg.Single_tuple -> "single_tuple"

let try_pg f =
  try Ok (f ()) with
  | Pg.Error err -> Or_error.error_string (Pg.string_of_error err)
  | exn -> Or_error.of_exn exn

let exec_raw t query params =
  Stdlib.Mutex.lock t.mutex;
  let result =
    let perform () =
      match params with
      | [] -> t.conn#exec query
      | _ ->
          let param_array =
            params
            |> List.map ~f:(function Some value -> value | None -> Pg.null)
            |> Array.of_list
          in
          t.conn#exec ~params:param_array query
    in
    match try_pg perform with
    | Error err -> Error err
    | Ok res -> (
        match res#status with
        | Pg.Command_ok
        | Pg.Tuples_ok -> Ok res
        | status ->
            let msg = String.strip t.conn#error_message in
            let message =
              if String.is_empty msg then
                Printf.sprintf "Postgres returned unexpected status %s" (string_of_status status)
              else msg
            in
            Or_error.error_string message)
  in
  Stdlib.Mutex.unlock t.mutex;
  result

let exec_unit t query params =
  let* _ = exec_raw t query params in
  Or_error.return ()

let parse_int field value =
  match Int.of_string value with
  | v -> Or_error.return v
  | exception _ -> Or_error.errorf "Expected integer for %s, got %s" field value

let fetch_optional_int t query params =
  let* result = exec_raw t query params in
  if Int.equal result#ntuples 0 then Or_error.return None
  else
    let value = result#getvalue 0 0 in
    let+ parsed = parse_int "id" value in
    Some parsed

let fetch_returning_int t query params =
  let* result = exec_raw t query params in
  if Int.equal result#ntuples 0 then Or_error.error_string "Query returned no rows"
  else
    let value = result#getvalue 0 0 in
    parse_int "id" value

let create conninfo =
  if String.is_empty (String.strip conninfo) then
    Or_error.error_string "Postgres connection string cannot be empty"
  else
    match Or_error.try_with (fun () -> new Pg.connection ~conninfo ()) with
    | Ok conn -> Or_error.return { conn; mutex = Stdlib.Mutex.create () }
    | Error err ->
        let exn = Error.to_exn err in
        (match exn with
        | Pg.Error pg_err -> Or_error.error_string (Pg.string_of_error pg_err)
        | _ -> Error err)

let normalize_eco_code s = String.uppercase (String.strip s)

let eco_filter value =
  let value = normalize_eco_code value in
  match String.split value ~on:'-' with
  | [ start_code; end_code ] when not (String.is_empty start_code) && not (String.is_empty end_code) ->
      `Range (start_code, end_code)
  | _ -> `Exact value

let select_player_by_fide t fide_id =
  fetch_optional_int
    t
    "SELECT id FROM players WHERE fide_id = $1 LIMIT 1"
    [ Some fide_id ]

let select_player_by_name t name =
  fetch_optional_int
    t
    "SELECT id FROM players WHERE name = $1 LIMIT 1"
    [ Some name ]

let insert_player t (player : Metadata.player) =
  fetch_returning_int
    t
    "INSERT INTO players (name, fide_id, rating_peak) VALUES ($1, $2, $3) RETURNING id"
    [ Some player.name
    ; Option.map player.fide_id ~f:Fn.id
    ; Option.map player.rating ~f:(fun rating -> Int.to_string rating)
    ]

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

let side_to_move ply = if Int.(ply % 2 = 1) then "black" else "white"

let insert_position t game_id (move : Pgn_parser.move) fen =
  let* fen = Fen.normalize fen in
  let side = side_to_move move.ply in
  let move_number =
    if Int.(move.turn <= 0) then None else Some (Int.to_string move.turn)
  in
  exec_unit
    t
    "WITH inserted AS (\n\
     INSERT INTO positions (game_id, ply, move_number, side_to_move, fen, san)\n\
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, fen)\n\
     INSERT INTO embedding_jobs (position_id, fen)\n\
     SELECT id, fen FROM inserted"
    [ Some (Int.to_string game_id)
    ; Some (Int.to_string move.ply)
    ; move_number
    ; Some side
    ; Some fen
    ; Some move.san
    ]

let rec insert_positions t game_id move_fens count =
  match move_fens with
  | [] -> Or_error.return count
  | (move, fen) :: rest ->
      let* () = insert_position t game_id move fen in
      insert_positions t game_id rest (count + 1)

let insert_game (repo : t) ~metadata ~pgn ~moves =
  let* fen_sequence = Pgn_to_fen.fens_of_string pgn in
  let move_count = List.length moves in
  let fen_count = List.length fen_sequence in
  if not (Int.equal move_count fen_count) then
    Or_error.errorf "PGN generated %d moves but %d FEN positions" move_count fen_count
  else (
    let* white_id = upsert_player repo metadata.Metadata.white in
    let* black_id = upsert_player repo metadata.Metadata.black in
    let params =
      [ Option.map white_id ~f:Int.to_string
      ; Option.map black_id ~f:Int.to_string
      ; Option.map metadata.event ~f:Fn.id
      ; Option.map metadata.site ~f:Fn.id
      ; Option.map metadata.round ~f:Fn.id
      ; Option.map metadata.date ~f:Fn.id
      ; Option.map metadata.eco_code ~f:Fn.id
      ; Option.map metadata.opening_name ~f:Fn.id
      ; Option.map metadata.opening_slug ~f:Fn.id
      ; Option.map metadata.result ~f:Fn.id
      ; Option.map metadata.white.rating ~f:Int.to_string
      ; Option.map metadata.black.rating ~f:Int.to_string
      ; Some pgn
      ]
    in
    let* game_id =
      fetch_returning_int
        repo
        "INSERT INTO games\n\
         (white_player_id, black_player_id, event, site, round, played_on, eco_code, opening_name, opening_slug, result, white_rating, black_rating, pgn)\n\
         VALUES ($1, $2, $3, $4, $5, $6::date, $7, $8, $9, $10, $11, $12, $13)\n\
         RETURNING id"
        params
    in
    let move_fens = List.zip_exn moves fen_sequence in
    let+ inserted = insert_positions repo game_id move_fens 0 in
    (game_id, inserted))

let option_of_field result row col =
  if result#getisnull row col then None else Some (result#getvalue row col)

let build_conditions ~filters ~rating =
  let conditions = ref [] in
  let params_rev = ref [] in
  let next_param = ref 1 in
  let add_param value =
    let placeholder = Printf.sprintf "$%d" !next_param in
    Int.incr next_param;
    params_rev := value :: !params_rev;
    placeholder
  in
  let add_string value = add_param (Some value) in
  let add_int value = add_param (Some (Int.to_string value)) in
  List.iter filters ~f:(fun (filter : Query_intent.metadata_filter) ->
      match String.lowercase filter.field with
      | "opening" ->
          let placeholder = add_string (String.lowercase (String.strip filter.value)) in
          conditions := Printf.sprintf "g.opening_slug = %s" placeholder :: !conditions
      | "result" ->
          let placeholder = add_string (String.strip filter.value) in
          conditions := Printf.sprintf "g.result = %s" placeholder :: !conditions
      | "eco_range" -> (
          match eco_filter filter.value with
          | `Range (start_code, end_code) ->
              let start_placeholder = add_string start_code in
              let end_placeholder = add_string end_code in
              conditions :=
                Printf.sprintf "g.eco_code BETWEEN %s AND %s" start_placeholder end_placeholder
                :: !conditions
          | `Exact single ->
              let placeholder = add_string single in
              conditions := Printf.sprintf "g.eco_code = %s" placeholder :: !conditions)
      | _ -> ());
  (match rating.Query_intent.white_min with
  | Some min ->
      let placeholder = add_int min in
      conditions := Printf.sprintf "g.white_rating >= %s" placeholder :: !conditions
  | None -> ());
  (match rating.Query_intent.black_min with
  | Some min ->
      let placeholder = add_int min in
      conditions := Printf.sprintf "g.black_rating >= %s" placeholder :: !conditions
  | None -> ());
  (match rating.Query_intent.max_rating_delta with
  | Some delta ->
      let placeholder = add_int delta in
      conditions :=
        Printf.sprintf
          "g.white_rating IS NOT NULL AND g.black_rating IS NOT NULL AND ABS(g.white_rating - g.black_rating) <= %s"
          placeholder
        :: !conditions
  | None -> ());
  let params = List.rev !params_rev in
  let next_index = !next_param in
  (List.rev !conditions, params, next_index)

let search_games repo ~filters ~rating ~limit =
  let limit = Int.max 1 limit in
  let conditions, params, next_index = build_conditions ~filters ~rating in
  let where_clause =
    if List.is_empty conditions then ""
    else "WHERE " ^ String.concat ~sep:" AND " conditions
  in
  let limit_placeholder = Printf.sprintf "$%d" next_index in
  let sql =
    Printf.sprintf
      "SELECT g.id,\n              COALESCE(w.name, ''),\n              COALESCE(b.name, ''),\n              g.result,\n              g.event,\n              g.opening_slug,\n              g.opening_name,\n              g.eco_code,\n              g.white_rating,\n              g.black_rating,\n              TO_CHAR(g.played_on, 'YYYY-MM-DD')\n       FROM games g\n       LEFT JOIN players w ON g.white_player_id = w.id\n       LEFT JOIN players b ON g.black_player_id = b.id\n       %s\n       ORDER BY g.played_on DESC NULLS LAST, g.id DESC\n       LIMIT %s"
      where_clause
      limit_placeholder
  in
  let params = params @ [ Some (Int.to_string limit) ] in
  let* result = exec_raw repo sql params in
  let tuples = result#ntuples in
  let rec build acc row =
    if row < 0 then acc
    else
      let summary =
        { id = Int.of_string (result#getvalue row 0)
        ; white = result#getvalue row 1
        ; black = result#getvalue row 2
        ; result = option_of_field result row 3
        ; event = option_of_field result row 4
        ; opening_slug = option_of_field result row 5
        ; opening_name = option_of_field result row 6
        ; eco_code = option_of_field result row 7
        ; white_rating = Option.bind (option_of_field result row 8) ~f:Int.of_string_opt
        ; black_rating = Option.bind (option_of_field result row 9) ~f:Int.of_string_opt
        ; played_on = option_of_field result row 10
        }
      in
      build (summary :: acc) (row - 1)
  in
  Or_error.return (build [] (tuples - 1))

let fetch_games_with_pgn repo ~ids =
  let unique_ids = ids |> List.dedup_and_sort ~compare:Int.compare in
  match unique_ids with
  | [] -> Or_error.return []
  | _ ->
      let placeholders, params =
        List.foldi unique_ids ~init:([], []) ~f:(fun idx (ph, params) id ->
            let placeholder = Printf.sprintf "$%d" (idx + 1) in
            (placeholder :: ph, Some (Int.to_string id) :: params))
      in
      let sql =
        Printf.sprintf
          "SELECT id, pgn FROM games WHERE id IN (%s)"
          (String.concat ~sep:"," (List.rev placeholders))
      in
      let* result = exec_raw repo sql (List.rev params) in
      let tuples = result#ntuples in
      let rec build acc row =
        if row < 0 then acc
        else
          let id = Int.of_string (result#getvalue row 0) in
          let pgn = result#getvalue row 1 in
          build ((id, pgn) :: acc) (row - 1)
      in
      Or_error.return (build [] (tuples - 1))

let parse_job_row result row =
  let value idx = result#getvalue row idx in
  let int_field name idx = parse_int name (value idx) in
  let status_field idx = Job.status_of_string (value idx) in
  let last_error =
    if result#getisnull row 4 then None else Some (value 4)
  in
  let* id = int_field "id" 0 in
  let fen = value 1 in
  let* attempts = int_field "attempts" 2 in
  let* status = status_field 3 in
  Or_error.return { Job.id; fen; attempts; status; last_error }

let pending_embedding_job_count repo =
  let* result =
    exec_raw
      repo
      "SELECT COUNT(*) FROM embedding_jobs WHERE status = 'pending'"
      []
  in
  let count =
    if Int.equal result#ntuples 0 then "0" else result#getvalue 0 0
  in
  match Int.of_string_opt count with
  | Some value -> Or_error.return value
  | None -> Or_error.errorf "Unexpected count value %s" count

let claim_pending_jobs repo ~limit =
  if Int.(limit <= 0) then Or_error.return []
  else
    let* result =
      exec_raw
        repo
        "WITH candidate AS (\n\
         SELECT id\n\
         FROM embedding_jobs\n\
         WHERE status = 'pending'\n\
         ORDER BY enqueued_at ASC\n\
         FOR UPDATE SKIP LOCKED\n\
         LIMIT $1\n\
         )\n\
         UPDATE embedding_jobs AS ej\n\
         SET status = 'in_progress', attempts = ej.attempts + 1, started_at = NOW(), last_error = NULL\n\
         WHERE ej.id IN (SELECT id FROM candidate)\n\
         RETURNING ej.id, ej.fen, ej.attempts, ej.status, ej.last_error"
        [ Some (Int.to_string limit) ]
    in
    let tuples = result#ntuples in
    let rec build acc row =
      if row < 0 then Or_error.return acc
      else
        match parse_job_row result row with
        | Ok job -> build (job :: acc) (row - 1)
        | Error err -> Error err
    in
    build [] (tuples - 1)

let mark_job_completed repo ~job_id ~vector_id =
  let vector_param =
    if String.is_empty (String.strip vector_id) then None else Some vector_id
  in
  exec_unit
    repo
    "WITH updated AS (\n\
     UPDATE embedding_jobs\n\
     SET status = 'completed', completed_at = NOW(), last_error = NULL\n\
     WHERE id = $1\n\
     RETURNING position_id)\n\
     UPDATE positions\n\
     SET vector_id = $2\n\
     WHERE id IN (SELECT position_id FROM updated)"
    [ Some (Int.to_string job_id); vector_param ]

let mark_job_failed repo ~job_id ~error =
  exec_unit
    repo
    "UPDATE embedding_jobs\n\
     SET status = 'failed', last_error = $1, completed_at = NULL\n\
     WHERE id = $2"
    [ Some error; Some (Int.to_string job_id) ]
