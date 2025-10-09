open! Base
open Stdio

module Pg = Postgresql

let template_env = "CHESSMATE_TEST_DATABASE_URL"

let ( let* ) t f = Or_error.bind t ~f
let ( let+ ) t f = Or_error.map t ~f

let () = Stdlib.Random.self_init ()

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

let try_pg f =
  try Ok (f ()) with
  | Pg.Error err -> Or_error.error_string (Pg.string_of_error err)
  | exn -> Or_error.of_exn exn

let random_db_name () =
  let pid = Unix.getpid () in
  let nonce = Stdlib.Random.bits () land 0xFFFFFF in
  Printf.sprintf "chessmate_it_%d_%06x" pid nonce

type env = {
  database_url : string;
  database_name : string;
  admin_url : string;
  source_root : string;
}

let with_connection conninfo f =
  let* conn =
    try_pg (fun () ->
        new Pg.connection
          ~conninfo:conninfo
          ())
  in
  Exn.protect
    ~f:(fun () -> f conn)
    ~finally:(fun () -> try conn#finish with _ -> ())

let exec_unit (conn : Pg.connection) sql =
  let* _ = try_pg (fun () -> conn#exec sql) in
  Or_error.return ()

let exec_unit_params (conn : Pg.connection) sql params =
  let array_params = Array.of_list params in
  let* _ = try_pg (fun () -> conn#exec ~params:array_params sql) in
  Or_error.return ()

let terminate_connections (conn : Pg.connection) database =
  exec_unit_params
    conn
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1"
    [ database ]

let create_database admin_url database_name =
  with_connection admin_url (fun conn ->
      exec_unit conn (Printf.sprintf "CREATE DATABASE %s;" database_name))

let drop_database admin_url database_name =
  with_connection admin_url (fun conn ->
      let* () = terminate_connections conn database_name in
      exec_unit conn (Printf.sprintf "DROP DATABASE IF EXISTS %s;" database_name))

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

let apply_migration conn path =
  let* contents = Or_error.try_with (fun () -> In_channel.read_all path) in
  exec_unit conn contents

let run_migrations env =
  with_connection env.database_url (fun conn ->
      let* files = migration_files env.source_root in
      if List.is_empty files then
        Or_error.error_string "No migration files found under scripts/migrations"
      else
        List.fold files ~init:(Or_error.return ()) ~f:(fun acc path ->
            let* () = acc in
            apply_migration conn path))

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
  let cleanup () =
    drop_database env.admin_url env.database_name
  in
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
  with_connection env.database_url (fun conn ->
      let* result = try_pg (fun () -> conn#exec sql) in
      if Int.equal result#ntuples 0 then Or_error.error_string "Query returned no rows"
      else (
        match Int.of_string_opt (result#getvalue 0 0) with
        | Some value -> Or_error.return value
        | None -> Or_error.errorf "Expected integer result for query: %s" sql))

let fetch_row env sql =
  with_connection env.database_url (fun conn ->
      let* result = try_pg (fun () -> conn#exec sql) in
      if Int.equal result#ntuples 0 then Or_error.error_string "Query returned no rows"
      else
        let cols = result#nfields in
        let values =
          List.init cols ~f:(fun idx ->
              if result#getisnull 0 idx then None else Some (result#getvalue 0 idx))
        in
        Or_error.return values)

let fixture_path name =
  Stdlib.Filename.concat (source_root ()) (Stdlib.Filename.concat "test/fixtures" name)

let ensure_psql_available () =
  (* Placeholder for future diagnostics; currently unused but kept for parity with tooling expectations. *)
  Or_error.return ()
