open! Base
open Stdio

module Blocking = Caqti_blocking
module Request = Caqti_request.Infix
module Std = Caqti_type.Std

let template_env = "CHESSMATE_TEST_DATABASE_URL"

let ( let* ) t f = Or_error.bind t ~f
let ( let+ ) t f = Or_error.map t ~f

let () = Stdlib.Random.self_init ()

let sanitize_error err = Caqti_error.show err |> String.strip

let or_caqti label result =
  match result with
  | Ok value -> Or_error.return value
  | Error err -> Or_error.errorf "%s: %s" label (sanitize_error err)

let source_root () =
  Stdlib.Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"."

let trimmed_env name =
  Stdlib.Sys.getenv_opt name
  |> Option.map ~f:String.strip
  |> Option.filter ~f:(fun value -> not (String.is_empty value))

let fetch_template () = trimmed_env template_env

let missing_template_message =
  Printf.sprintf
    "Set %s to a Postgres connection string with privileges to create and drop databases for integration tests."
    template_env

let random_db_name () =
  let pid = Unix.getpid () in
  let nonce = Stdlib.Random.bits () land 0xFFFFFF in
  Printf.sprintf "chessmate_it_%d_%06x" pid nonce

let is_safe_database_name name =
  String.for_all name ~f:(function
    | 'a' .. 'z'
    | 'A' .. 'Z'
    | '0' .. '9'
    | '_' -> true
    | _ -> false)

let with_connection conninfo f =
  let uri = Uri.of_string conninfo in
  match Blocking.connect uri with
  | Error err ->
      Or_error.errorf "Failed to connect to %s: %s" conninfo (sanitize_error err)
  | Ok connection ->
      Exn.protect
        ~f:(fun () -> f connection)
        ~finally:(fun () ->
          let module Conn = (val connection : Blocking.CONNECTION) in
          Conn.disconnect ())

let exec_unit connection ~label sql =
  let module Conn = (val connection : Blocking.CONNECTION) in
  let request = Request.(Std.unit ->. Std.unit @@ sql) in
  or_caqti label (Conn.exec request ())

let terminate_connections connection database =
  let module Conn = (val connection : Blocking.CONNECTION) in
  let request =
    Request.(Std.string ->. Std.unit)
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ?"
  in
  or_caqti "terminate connections" (Conn.exec request database)

type env = {
  database_url : string;
  database_name : string;
  admin_url : string;
  source_root : string;
}

let create_database admin_url database_name =
  if not (is_safe_database_name database_name) then
    Or_error.errorf "Unsafe database name %s" database_name
  else
    with_connection admin_url (fun connection ->
        exec_unit
          connection
          ~label:"create database"
          (Printf.sprintf "CREATE DATABASE \"%s\";" database_name))

let drop_database admin_url database_name =
  with_connection admin_url (fun connection ->
      let* () = terminate_connections connection database_name in
      exec_unit
        connection
        ~label:"drop database"
        (Printf.sprintf "DROP DATABASE IF EXISTS \"%s\";" database_name))

let migrations_dir root = Stdlib.Filename.concat root "scripts/migrations"

let migration_files root =
  let dir = migrations_dir root in
  match Stdlib.Sys.readdir dir with
  | exception Stdlib.Sys_error msg -> Or_error.error_string msg
  | entries ->
      entries
      |> Array.to_list
      |> List.filter_map ~f:(fun entry ->
             if Stdlib.Filename.check_suffix entry ".sql" then
               Some (Stdlib.Filename.concat dir entry)
             else None)
      |> List.sort ~compare:String.compare
      |> Or_error.return

let apply_migration connection path =
  let* contents = Or_error.try_with (fun () -> In_channel.read_all path) in
  exec_unit connection ~label:(Printf.sprintf "apply migration %s" path) contents

let run_migrations env =
  with_connection env.database_url (fun connection ->
      let* files = migration_files env.source_root in
      if List.is_empty files then
        Or_error.error_string "No migration files found under scripts/migrations"
      else
        List.fold files ~init:(Or_error.return ()) ~f:(fun acc path ->
            let* () = acc in
            apply_migration connection path))

let protect ~f ~cleanup =
  match f () with
  | Ok _ as ok ->
      let (_ : unit Or_error.t) = cleanup () in
      ok
  | Error _ as err ->
      let (_ : unit Or_error.t) = cleanup () in
      err

let configure_env env =
  let vars = [ "DATABASE_URL", env.database_url ] in
  let originals =
    List.map vars ~f:(fun (name, value) -> name, Stdlib.Sys.getenv_opt name, value)
  in
  List.iter originals ~f:(fun (name, _, value) -> Unix.putenv name value);
  fun () ->
    List.iter originals ~f:(fun (name, original, _) ->
        match original with
        | Some value -> Unix.putenv name value
        | None -> Unix.putenv name "");
    Or_error.return ()

let with_initialized_database ~template ~f =
  let uri = Uri.of_string template in
  let admin_uri = Uri.with_path uri "/postgres" in
  let database_name = random_db_name () in
  let database_uri = Uri.with_path uri ("/" ^ database_name) in
  let env =
    { database_url = Uri.to_string database_uri
    ; database_name
    ; admin_url = Uri.to_string admin_uri
    ; source_root = source_root () }
  in
  let setup () =
    let* () = create_database env.admin_url env.database_name in
    let* () = run_migrations env in
    let teardown_env = configure_env env in
    Or_error.return teardown_env
  in
  let cleanup () = drop_database env.admin_url env.database_name in
  match setup () with
  | Error _ as err ->
      let (_ : unit Or_error.t) = cleanup () in
      err
  | Ok restore_env ->
      protect
        ~f:(fun () ->
          Exn.protect
            ~f:(fun () -> f env)
            ~finally:(fun () ->
              let (_ : unit Or_error.t) = restore_env () in
              ()))
        ~cleanup

let scalar_int env sql =
  with_connection env.database_url (fun connection ->
      let module Conn = (val connection : Blocking.CONNECTION) in
      let request = Request.(Std.unit ->! Std.int @@ sql) in
      or_caqti sql (Conn.find request ()))

let fetch_row env sql =
  with_connection env.database_url (fun connection ->
      let module Conn = (val connection : Blocking.CONNECTION) in
      let request = Request.(Std.unit ->? Std.string @@ sql) in
      match or_caqti sql (Conn.find_opt request ()) with
      | Error _ as err -> err
      | Ok None -> Or_error.error_string "Query returned no rows"
      | Ok (Some value) -> Or_error.return [ Some value ])

let fixture_path name =
  Stdlib.Filename.concat (source_root ()) (Stdlib.Filename.concat "test/fixtures" name)

let ensure_psql_available () = Or_error.return ()

let with_required_template ~f =
  match fetch_template () with
  | Some template -> f template
  | None -> Or_error.error_string missing_template_message
