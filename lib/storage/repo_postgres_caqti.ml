open! Base

(** Implementation backing {!Repo_postgres_caqti}: thin wrappers around blocking
    Caqti queries plus helpers used by the API, CLI, and embedding worker. All
    database interaction flows through this module so the application can share
    a single pool and a consistent error surface. *)

module Blocking = Caqti_blocking
module Pool = Blocking.Pool
module Pool_config = Caqti_pool_config
module Error = Caqti_error

let sanitize_error err = Sanitizer.sanitize_string (Error.show err)

let pool_config ?pool_size () =
  match pool_size with
  | None -> Pool_config.default_from_env ()
  | Some size ->
      let default = Pool_config.default_from_env () in
      Pool_config.set Pool_config.max_size size default

let parse_pool_size ~env_var ~default =
  match Config.Helpers.optional ~strip:true env_var with
  | None -> default
  | Some raw -> (
      match Config.Helpers.parse_positive_int env_var raw with
      | Ok value -> value
      | Error _ -> default)

let default_pool_size = 10
let pool_size_env = "CHESSMATE_DB_POOL_SIZE"

let or_error label result =
  match result with
  | Ok value -> Or_error.return value
  | Error err -> Or_error.errorf "%s: %s" label (sanitize_error err)

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
         {
           pool;
           capacity = pool_size;
           stats_mutex = Stdlib.Mutex.create ();
           in_use = 0;
           waiting = 0;
         })

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

type stats = { capacity : int; in_use : int; waiting : int }

let stats t =
  Stdlib.Mutex.lock t.stats_mutex;
  let snapshot =
    {
      capacity = t.capacity;
      in_use = Int.max 0 t.in_use;
      waiting = Int.max 0 t.waiting;
    }
  in
  Stdlib.Mutex.unlock t.stats_mutex;
  snapshot

module Std = Caqti_type.Std
module Request = Caqti_request.Infix
module Metadata = Game_metadata
module Job = Embedding_job

let ( let* ) x f = Result.bind x ~f

type parameter = Param_string of string | Param_int of int

type condition_build_result = {
  conditions : string list;
  parameters : parameter list;
}

let normalize_eco_code s = String.uppercase (String.strip s)

let eco_filter value =
  let value = normalize_eco_code value in
  match String.split value ~on:'-' with
  | [ start_code; end_code ]
    when (not (String.is_empty start_code)) && not (String.is_empty end_code) ->
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
                ("g.eco_code BETWEEN " ^ start_placeholder ^ " AND "
               ^ end_placeholder)
                :: !conditions
          | `Exact single ->
              let placeholder = add_string single in
              conditions := ("g.eco_code = " ^ placeholder) :: !conditions)
      | field -> (
          match column_of_field field with
          | Some (`Case_insensitive column) ->
              let placeholder = add_string (sanitize_lower filter.value) in
              conditions :=
                ("LOWER(" ^ column ^ ") = " ^ placeholder) :: !conditions
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
        ("g.white_rating IS NOT NULL AND g.black_rating IS NOT NULL AND \
          ABS(g.white_rating - g.black_rating) <= " ^ placeholder)
        :: !conditions
  | None -> ());
  { conditions = List.rev !conditions; parameters = List.rev !params_rev }

module Dynparam = struct
  type t = Pack : 'a Caqti_type.t * 'a -> t

  let empty = Pack (Std.unit, ())
  let add_string value (Pack (t, v)) = Pack (Std.t2 t Std.string, (v, value))
  let add_int value (Pack (t, v)) = Pack (Std.t2 t Std.int, (v, value))
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

type vector_payload = { position_id : int; game_id : int; json : Yojson.Safe.t }

let search_games repo ~filters ~rating ~limit =
  let limit = Int.max 1 limit in
  let build_result = build_conditions_internal ~filters ~rating in
  let where_clause_line =
    match build_result.conditions with
    | [] -> ""
    | conditions ->
        Printf.sprintf "WHERE %s\n" (String.concat ~sep:" AND " conditions)
  in
  let params = build_result.parameters @ [ Param_int limit ] in
  let params_pack =
    List.fold params ~init:Dynparam.empty ~f:(fun pack -> function
      | Param_string value -> Dynparam.add_string value pack
      | Param_int value -> Dynparam.add_int value pack)
  in
  let (Dynparam.Pack (param_type, param_value)) = params_pack in
  let row_type =
    Std.t11 Std.int Std.string Std.string (Std.option Std.string)
      (Std.option Std.string) (Std.option Std.string) (Std.option Std.string)
      (Std.option Std.string) (Std.option Std.int) (Std.option Std.int)
      (Std.option Std.string)
  in
  let sql =
    String.concat
      [
        "SELECT g.id,\n";
        "       COALESCE(w.name, ''),\n";
        "       COALESCE(b.name, ''),\n";
        "       g.result,\n";
        "       g.event,\n";
        "       g.opening_slug,\n";
        "       g.opening_name,\n";
        "       g.eco_code,\n";
        "       g.white_rating,\n";
        "       g.black_rating,\n";
        "       TO_CHAR(g.played_on, 'YYYY-MM-DD')\n";
        "FROM games g\n";
        "LEFT JOIN players w ON g.white_player_id = w.id\n";
        "LEFT JOIN players b ON g.black_player_id = b.id\n";
        where_clause_line;
        "ORDER BY g.played_on DESC NULLS LAST, g.id DESC\n";
        "LIMIT ?";
      ]
  in
  let request = Request.(param_type ->* row_type) ~oneshot:true sql in
  with_connection repo (fun conn ->
      let module Conn = (val conn : Blocking.CONNECTION) in
      Conn.collect_list request param_value)
  |> Or_error.map
       ~f:
         (List.map
            ~f:(fun
                ( id,
                  white,
                  black,
                  result,
                  event,
                  opening_slug,
                  opening_name,
                  eco_code,
                  white_rating,
                  black_rating,
                  played_on )
              ->
              {
                id;
                white;
                black;
                result;
                event;
                opening_slug;
                opening_name;
                eco_code;
                white_rating;
                black_rating;
                played_on;
              }))

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

let select_player_by_fide_request =
  Request.(Std.string ->? Std.int)
    "SELECT id FROM players WHERE fide_id = ? LIMIT 1"

let select_player_by_name_request =
  Request.(Std.string ->? Std.int)
    "SELECT id FROM players WHERE name = ? LIMIT 1"

let insert_player_request =
  Request.(
    Std.t3 Std.string (Std.option Std.string) (Std.option Std.int) ->! Std.int)
    "INSERT INTO players (name, fide_id, rating_peak) VALUES (?, ?, ?) \
     RETURNING id"

let insert_position_request =
  let open Request in
  Std.t6 Std.int Std.int (Std.option Std.int) Std.string Std.string Std.string
  ->. Std.unit
  @@ {|
WITH inserted AS (
  INSERT INTO positions
    (game_id, ply, move_number, side_to_move, fen, san)
  VALUES (?, ?, ?, ?, ?, ?)
  RETURNING id, fen)
INSERT INTO embedding_jobs (position_id, fen)
SELECT id, fen FROM inserted
|}

let insert_game_request =
  let param_type =
    Std.t2
      (Std.t7 (Std.option Std.int) (Std.option Std.int) (Std.option Std.string)
         (Std.option Std.string) (Std.option Std.string) (Std.option Std.string)
         (Std.option Std.string))
      (Std.t6 (Std.option Std.string) (Std.option Std.string)
         (Std.option Std.string) (Std.option Std.int) (Std.option Std.int)
         Std.string)
  in
  let open Request in
  (param_type ->! Std.int)
  @@ {|
INSERT INTO games
  (white_player_id, black_player_id, event, site, round, played_on,
   eco_code, opening_name, opening_slug, result, white_rating,
   black_rating, pgn)
VALUES (?, ?, ?, ?, ?, ?::date, ?, ?, ?, ?, ?, ?, ?)
RETURNING id
|}

let claim_pending_jobs_request =
  let open Request in
  Std.int
  ->* Std.t5 Std.int Std.string Std.int Std.string (Std.option Std.string)
  @@ {|
WITH candidate AS (
  SELECT id
  FROM embedding_jobs
  WHERE status = 'pending'
  ORDER BY enqueued_at ASC
  FOR UPDATE SKIP LOCKED
  LIMIT ?
)
UPDATE embedding_jobs AS ej
SET status = 'in_progress',
    attempts = ej.attempts + 1,
    started_at = NOW(),
    last_error = NULL
WHERE ej.id IN (SELECT id FROM candidate)
RETURNING ej.id, ej.fen, ej.attempts, ej.status, ej.last_error
|}

let mark_job_completed_request =
  let open Request in
  (Std.t2 Std.int (Std.option Std.string) ->. Std.unit)
  @@ {|
WITH updated AS (
  UPDATE embedding_jobs
  SET status = 'completed', completed_at = NOW(), last_error = NULL
  WHERE id = ?
  RETURNING position_id)
UPDATE positions
SET vector_id = ?
WHERE id IN (SELECT position_id FROM updated)
|}

let mark_job_failed_request =
  let open Request in
  (Std.t2 Std.string Std.int ->. Std.unit)
  @@ {|
UPDATE embedding_jobs
SET status = 'failed', last_error = ?, completed_at = NULL
WHERE id = ?
|}

let vector_payload_request =
  let row_type =
    Std.t2
      (Std.t11 Std.int Std.int Std.int (Std.option Std.string)
         (Std.option Std.string) (Std.option Std.string) (Std.option Std.string)
         (Std.option Std.string) (Std.option Std.string) (Std.option Std.string)
         (Std.option Std.int))
      (Std.t3 (Std.option Std.int) (Std.option Std.string)
         (Std.option Std.string))
  in
  let open Request in
  (Std.int ->? row_type)
  @@ {|
SELECT ej.position_id,
       p.game_id,
       p.ply,
       p.tags,
       p.san,
       p.side_to_move,
       g.opening_slug,
       g.opening_name,
       g.eco_code,
       g.result,
       g.white_rating,
       g.black_rating,
       w.name,
       b.name
FROM embedding_jobs ej
JOIN positions p ON p.id = ej.position_id
JOIN games g ON g.id = p.game_id
LEFT JOIN players w ON g.white_player_id = w.id
LEFT JOIN players b ON g.black_player_id = b.id
WHERE ej.id = ?
LIMIT 1
|}

let sanitize_optional_string = function
  | None -> None
  | Some raw ->
      let trimmed = String.strip raw in
      if String.is_empty trimmed then None else Some trimmed

let side_to_move ply = if Int.(ply % 2 = 1) then "black" else "white"

let upsert_player conn (player : Metadata.player) =
  let module Conn = (val conn : Blocking.CONNECTION) in
  let name = String.strip player.name in
  if String.is_empty name then Ok None
  else
    let fide_id = sanitize_optional_string player.fide_id in
    let* by_fide =
      match fide_id with
      | None -> Ok None
      | Some fid -> Conn.find_opt select_player_by_fide_request fid
    in
    match by_fide with
    | Some id -> Ok (Some id)
    | None -> (
        let* existing = Conn.find_opt select_player_by_name_request name in
        match existing with
        | Some id -> Ok (Some id)
        | None ->
            let params = (name, fide_id, player.rating) in
            let* id = Conn.find insert_player_request params in
            Ok (Some id))

let insert_positions conn game_id move_fens =
  let module Conn = (val conn : Blocking.CONNECTION) in
  List.fold_result move_fens ~init:0 ~f:(fun acc (move, fen) ->
      let { Pgn_parser.turn; ply; san } = move in
      let move_number = if Int.(turn <= 0) then None else Some turn in
      let side = side_to_move ply in
      let params = (game_id, ply, move_number, side, fen, san) in
      match Conn.exec insert_position_request params with
      | Ok () -> Ok (acc + 1)
      | Error err -> Error err)

let insert_game repo ~metadata ~pgn ~moves =
  let* fen_sequence = Pgn_to_fen.fens_of_string pgn in
  let move_count = List.length moves in
  let fen_count = List.length fen_sequence in
  if not (Int.equal move_count fen_count) then
    Or_error.errorf "PGN generated %d moves but %d FEN positions" move_count
      fen_count
  else
    let* normalized_fens =
      fen_sequence |> List.map ~f:Fen.normalize |> Or_error.all
    in
    let move_fens = List.zip_exn moves normalized_fens in
    with_connection repo (fun conn ->
        let module Conn = (val conn : Blocking.CONNECTION) in
        let rollback_error err =
          let (_ : (unit, Caqti_error.t) Result.t) = Conn.rollback () in
          Error err
        in
        let bind result f =
          match result with
          | Ok value -> f value
          | Error err -> rollback_error err
        in
        let params_for_game ~white_id ~black_id =
          let {
            Metadata.event;
            site;
            date;
            round;
            eco_code;
            opening_name;
            opening_slug;
            result;
            white;
            black;
          } =
            metadata
          in
          ( (white_id, black_id, event, site, round, date, eco_code),
            (opening_name, opening_slug, result, white.rating, black.rating, pgn)
          )
        in
        bind (Conn.start ()) (fun () ->
            bind (upsert_player conn metadata.white) (fun white_id ->
                bind (upsert_player conn metadata.black) (fun black_id ->
                    let params = params_for_game ~white_id ~black_id in
                    bind (Conn.find insert_game_request params) (fun game_id ->
                        bind (insert_positions conn game_id move_fens)
                          (fun inserted ->
                            bind (Conn.commit ()) (fun () ->
                                Ok (game_id, inserted))))))))

let claim_pending_jobs repo ~limit =
  if Int.(limit <= 0) then Or_error.return []
  else
    let* rows =
      with_connection repo (fun conn ->
          let module Conn = (val conn : Blocking.CONNECTION) in
          Conn.collect_list claim_pending_jobs_request limit)
    in
    rows
    |> List.fold_result ~init:[]
         ~f:(fun acc (id, fen, attempts, status, last_error) ->
           match Job.status_of_string status with
           | Ok parsed_status ->
               Ok
                 ({ Job.id; fen; attempts; status = parsed_status; last_error }
                 :: acc)
           | Error err -> Error err)
    |> Or_error.map ~f:List.rev

let mark_job_completed repo ~job_id ~vector_id =
  let vector =
    let trimmed = String.strip vector_id in
    if String.is_empty trimmed then None else Some trimmed
  in
  with_connection repo (fun conn ->
      let module Conn = (val conn : Blocking.CONNECTION) in
      Conn.exec mark_job_completed_request (job_id, vector))
  |> Or_error.map ~f:ignore

let mark_job_failed repo ~job_id ~error =
  with_connection repo (fun conn ->
      let module Conn = (val conn : Blocking.CONNECTION) in
      Conn.exec mark_job_failed_request (error, job_id))
  |> Or_error.map ~f:ignore

let json_list field =
  match field with
  | `Null -> []
  | `String s -> if String.is_empty (String.strip s) then [] else [ s ]
  | `List elements ->
      elements
      |> List.filter_map ~f:(function
           | `String s when not (String.is_empty (String.strip s)) -> Some s
           | _ -> None)
  | _ -> []

let add_opt_string ~key ~value acc =
  match value with None -> acc | Some v -> (key, `String v) :: acc

let add_opt_int ~key ~value acc =
  match value with None -> acc | Some v -> (key, `Int v) :: acc

let vector_payload_for_job repo ~job_id =
  let* row_opt =
    with_connection repo (fun conn ->
        let module Conn = (val conn : Blocking.CONNECTION) in
        Conn.find_opt vector_payload_request job_id)
  in
  match row_opt with
  | None ->
      Or_error.errorf
        "Unable to build vector payload: embedding job %d not found" job_id
  | Some
      ( ( position_id,
          game_id,
          ply,
          raw_tags,
          san,
          side_to_move,
          opening_slug,
          opening_name,
          eco_code,
          result,
          white_rating ),
        (black_rating, white_name, black_name) ) ->
      let tags =
        match raw_tags with
        | None -> `Assoc []
        | Some raw -> (
            try Yojson.Safe.from_string raw
            with Yojson.Json_error _ -> `Assoc [])
      in
      let phases = tags |> Yojson.Safe.Util.member "phases" |> json_list in
      let themes = tags |> Yojson.Safe.Util.member "themes" |> json_list in
      let keywords = tags |> Yojson.Safe.Util.member "keywords" |> json_list in
      let fields =
        []
        |> add_opt_string ~key:"san" ~value:san
        |> add_opt_string ~key:"side_to_move" ~value:side_to_move
        |> add_opt_string ~key:"opening_slug" ~value:opening_slug
        |> add_opt_string ~key:"opening_name" ~value:opening_name
        |> add_opt_string ~key:"eco" ~value:eco_code
        |> add_opt_string ~key:"result" ~value:result
        |> add_opt_int ~key:"white_elo" ~value:white_rating
        |> add_opt_int ~key:"black_elo" ~value:black_rating
        |> add_opt_string ~key:"white" ~value:white_name
        |> add_opt_string ~key:"black" ~value:black_name
      in
      let json =
        `Assoc
          ([
             ("game_id", `Int game_id);
             ("position_id", `Int position_id);
             ("ply", `Int ply);
             ("phases", `List (List.map phases ~f:(fun s -> `String s)));
             ("themes", `List (List.map themes ~f:(fun s -> `String s)));
             ("keywords", `List (List.map keywords ~f:(fun s -> `String s)));
           ]
          @ fields)
      in
      Or_error.return { position_id; game_id; json }

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
