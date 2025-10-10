open! Base

module Blocking = Caqti_blocking
module Pool = Blocking.Pool
module Pool_config = Caqti_pool_config
module Error = Caqti_error

let sanitize_error err =
  Sanitizer.sanitize_string (Error.show err)

let pool_config ?pool_size () =
  match pool_size with
  | None -> Pool_config.default_from_env ()
  | Some size ->
      let default = Pool_config.default_from_env () in
      Pool_config.set Pool_config.max_size size default

let parse_pool_size ~env_var ~default =
  match Stdlib.Sys.getenv_opt env_var with
  | None -> default
  | Some raw -> (
      match Int.of_string_opt (String.strip raw) with
      | Some value when value > 0 -> value
      | _ -> default)

let default_pool_size = 10
let pool_size_env = "CHESSMATE_DB_POOL_SIZE"

let or_error label result =
  match result with
  | Ok value -> Or_error.return value
  | Error err ->
      Or_error.errorf "%s: %s" label (sanitize_error err)

type t = {
  pool : (Blocking.connection, Error.t) Pool.t;
  capacity : int;
  stats_mutex : Stdlib.Mutex.t;
  mutable in_use : int;
  mutable waiting : int;
}

let create ?pool_size conninfo =
  let pool_size =
    match pool_size with
    | Some size -> size
    | None -> parse_pool_size ~env_var:pool_size_env ~default:default_pool_size
  in
  let uri = Uri.of_string conninfo in
  let config = pool_config ~pool_size () in
  Blocking.connect_pool ~pool_config:config uri
  |> or_error "Failed to connect to Postgres"
  |> Or_error.map ~f:(fun pool ->
         { pool; capacity = pool_size; stats_mutex = Stdlib.Mutex.create (); in_use = 0; waiting = 0 })

let with_connection t f =
  Stdlib.Mutex.lock t.stats_mutex;
  t.waiting <- t.waiting + 1;
  Stdlib.Mutex.unlock t.stats_mutex;
  let ran = ref false in
  let run conn =
    ran := true;
    Stdlib.Mutex.lock t.stats_mutex;
    t.waiting <- Int.max 0 (t.waiting - 1);
    t.in_use <- t.in_use + 1;
    Stdlib.Mutex.unlock t.stats_mutex;
    match f conn with
    | Ok value ->
        Stdlib.Mutex.lock t.stats_mutex;
        t.in_use <- t.in_use - 1;
        Stdlib.Mutex.unlock t.stats_mutex;
        Ok value
    | Error err ->
        Stdlib.Mutex.lock t.stats_mutex;
        t.in_use <- t.in_use - 1;
        Stdlib.Mutex.unlock t.stats_mutex;
        Error err
  in
  let result = Pool.use run t.pool in
  if not !ran then (
    Stdlib.Mutex.lock t.stats_mutex;
    t.waiting <- Int.max 0 (t.waiting - 1);
    Stdlib.Mutex.unlock t.stats_mutex);
  match result with
  | Ok value -> Or_error.return value
  | Error err ->
      Stdlib.Mutex.lock t.stats_mutex;
      t.waiting <- Int.max 0 (t.waiting - 1);
      Stdlib.Mutex.unlock t.stats_mutex;
      let sanitized = sanitize_error err in
      if !ran then Or_error.errorf "Postgres pool failure: %s" sanitized
      else Or_error.errorf "Postgres query failed: %s" sanitized

let disconnect t = Pool.drain t.pool

type stats = {
  capacity : int;
  in_use : int;
  waiting : int;
}

let stats t =
  Stdlib.Mutex.lock t.stats_mutex;
  let snapshot =
    { capacity = t.capacity
    ; in_use = Int.max 0 t.in_use
    ; waiting = Int.max 0 t.waiting }
  in
  Stdlib.Mutex.unlock t.stats_mutex;
  snapshot

module Std = Caqti_type.Std
module Request = Caqti_request.Infix

type parameter =
  | Param_string of string
  | Param_int of int

type condition_build_result = {
  conditions : string list;
  parameters : parameter list;
}

let normalize_eco_code s = String.uppercase (String.strip s)

let eco_filter value =
  let value = normalize_eco_code value in
  match String.split value ~on:'-' with
  | [ start_code; end_code ]
    when not (String.is_empty start_code) && not (String.is_empty end_code) ->
      `Range (start_code, end_code)
  | _ -> `Exact value

let build_conditions_internal ~filters ~rating =
  let conditions = ref [] in
  let params_rev = ref [] in
  let add_param param =
    params_rev := param :: !params_rev;
    "?"
  in
  let add_string value = add_param (Param_string value) in
  let add_int value = add_param (Param_int value) in
  let sanitize value = String.strip value in
  let sanitize_lower value = String.lowercase (sanitize value) in
  let column_of_field = function
    | "opening" | "opening_slug" -> Some (`Case_insensitive "g.opening_slug")
    | "event" -> Some (`Case_insensitive "g.event")
    | "result" -> Some (`Case_sensitive "g.result")
    | "white" | "white_player" -> Some (`Case_insensitive "w.name")
    | "black" | "black_player" -> Some (`Case_insensitive "b.name")
    | _ -> None
  in
  List.iter filters ~f:(fun (filter : Query_intent.metadata_filter) ->
      match String.lowercase (String.strip filter.field) with
      | "eco_range" -> (
          match eco_filter filter.value with
          | `Range (start_code, end_code) ->
              let start_placeholder = add_string start_code in
              let end_placeholder = add_string end_code in
              conditions :=
                ("g.eco_code BETWEEN " ^ start_placeholder ^ " AND " ^ end_placeholder)
                :: !conditions
          | `Exact single ->
              let placeholder = add_string single in
              conditions := ("g.eco_code = " ^ placeholder) :: !conditions)
      | field -> (
          match column_of_field field with
          | Some (`Case_insensitive column) ->
              let placeholder = add_string (sanitize_lower filter.value) in
              conditions := ("LOWER(" ^ column ^ ") = " ^ placeholder) :: !conditions
          | Some (`Case_sensitive column) ->
              let placeholder = add_string (sanitize filter.value) in
              conditions := (column ^ " = " ^ placeholder) :: !conditions
          | None -> ()));
  (match rating.Query_intent.white_min with
  | Some min ->
      let placeholder = add_int min in
      conditions := ("g.white_rating >= " ^ placeholder) :: !conditions
  | None -> ());
  (match rating.Query_intent.black_min with
  | Some min ->
      let placeholder = add_int min in
      conditions := ("g.black_rating >= " ^ placeholder) :: !conditions
  | None -> ());
  (match rating.Query_intent.max_rating_delta with
  | Some delta ->
      let placeholder = add_int delta in
      conditions :=
        ( "g.white_rating IS NOT NULL AND g.black_rating IS NOT NULL AND ABS(g.white_rating - g.black_rating) <= "
        ^ placeholder )
        :: !conditions
  | None -> ());
  { conditions = List.rev !conditions; parameters = List.rev !params_rev }

module Dynparam = struct
  type t = Pack : 'a Caqti_type.t * 'a -> t

  let empty = Pack (Std.unit, ())

  let add_string value (Pack (t, v)) =
    Pack (Std.t2 t Std.string, (v, value))

  let add_int value (Pack (t, v)) =
    Pack (Std.t2 t Std.int, (v, value))
end

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

let search_games repo ~filters ~rating ~limit =
  let limit = Int.max 1 limit in
  let build_result = build_conditions_internal ~filters ~rating in
  let where_clause =
    if List.is_empty build_result.conditions then ""
    else "WHERE " ^ String.concat ~sep:" AND " build_result.conditions
  in
  let params = build_result.parameters @ [ Param_int limit ] in
  let params_pack =
    List.fold params ~init:Dynparam.empty ~f:(fun pack -> function
      | Param_string value -> Dynparam.add_string value pack
      | Param_int value -> Dynparam.add_int value pack)
  in
  let Dynparam.Pack (param_type, param_value) = params_pack in
  let row_type =
    Std.t11
      Std.int
      Std.string
      Std.string
      (Std.option Std.string)
      (Std.option Std.string)
      (Std.option Std.string)
      (Std.option Std.string)
      (Std.option Std.string)
      (Std.option Std.int)
      (Std.option Std.int)
      (Std.option Std.string)
  in
  let sql =
    Printf.sprintf
      "SELECT g.id,\
              COALESCE(w.name, ''),\
              COALESCE(b.name, ''),\
              g.result,\
              g.event,\
              g.opening_slug,\
              g.opening_name,\
              g.eco_code,\
              g.white_rating,\
              g.black_rating,\
              TO_CHAR(g.played_on, 'YYYY-MM-DD')\
       FROM games g\
       LEFT JOIN players w ON g.white_player_id = w.id\
       LEFT JOIN players b ON g.black_player_id = b.id\
       %s\
       ORDER BY g.played_on DESC NULLS LAST, g.id DESC\
       LIMIT ?"
      where_clause
  in
  let request = Request.(param_type ->* row_type) ~oneshot:true sql in
  with_connection repo (fun conn ->
      let module Conn = (val conn : Blocking.CONNECTION) in
      Conn.collect_list request param_value)
  |> Or_error.map ~f:(List.map ~f:(fun ( id
                                       , white
                                       , black
                                       , result
                                       , event
                                       , opening_slug
                                       , opening_name
                                       , eco_code
                                       , white_rating
                                       , black_rating
                                       , played_on ) ->
         { id
         ; white
         ; black
         ; result
         ; event
         ; opening_slug
         ; opening_name
         ; eco_code
         ; white_rating
         ; black_rating
         ; played_on }))

let pending_embedding_job_count_request =
  Request.(Std.unit ->! Std.int)
    "SELECT COUNT(*) FROM embedding_jobs WHERE status = 'pending'"

let pending_embedding_job_count repo =
  with_connection repo (fun conn ->
      let module Conn = (val conn : Blocking.CONNECTION) in
      Conn.find pending_embedding_job_count_request ())

let fetch_games_with_pgn_request =
  Request.(Std.string ->* Std.t2 Std.int Std.string)
    "SELECT id, pgn FROM games WHERE id = ANY($1::int[])"

let fetch_games_with_pgn repo ~ids =
  let unique_ids = ids |> List.dedup_and_sort ~compare:Int.compare in
  match unique_ids with
  | [] -> Or_error.return []
  | _ ->
      let array_literal =
        "{"
        ^ String.concat ~sep:","
            (List.map unique_ids ~f:(fun id -> Int.to_string id))
        ^ "}"
      in
      with_connection repo (fun conn ->
          let module Conn = (val conn : Blocking.CONNECTION) in
          Conn.collect_list fetch_games_with_pgn_request array_literal)

module Private = struct
  let build_conditions ~filters ~rating =
    let result = build_conditions_internal ~filters ~rating in
  let params =
    List.map result.parameters ~f:(function
      | Param_string value -> Some value
      | Param_int value -> Some (Int.to_string value))
  in
    (result.conditions, params, List.length params + 1)
end
