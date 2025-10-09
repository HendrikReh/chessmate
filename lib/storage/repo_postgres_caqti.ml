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
  |> Or_error.map ~f:(fun pool -> { pool })

let with_connection t f =
  Pool.use f t.pool |> or_error "Postgres query failed"

let disconnect t = Pool.drain t.pool

let stats t =
  let size = Pool.size t.pool in
  `Assoc [ "max", `Int size ]
