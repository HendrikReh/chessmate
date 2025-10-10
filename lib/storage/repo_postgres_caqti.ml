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
