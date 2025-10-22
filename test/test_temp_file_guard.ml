open! Base
open Alcotest
open Chessmate

let require_path = function
  | Ok path -> path
  | Error err ->
      failf "failed to create temp file: %s" (Error.to_string_hum err)

let file_exists path = Stdlib.Sys.file_exists path
let ensure_cleanup () = Temp_file_guard.cleanup_now ()

let test_create_uses_system_temp () =
  ensure_cleanup ();
  let path =
    require_path
      (Temp_file_guard.create ~prefix:"temp_guard_test" ~suffix:".tmp" ())
  in
  check bool "file created" true (file_exists path);
  let dir = Stdlib.Filename.dirname path in
  check string "uses system temp dir" (Stdlib.Filename.get_temp_dir_name ()) dir;
  ensure_cleanup ();
  (* cleanup should remove the file *)
  check bool "file removed" false (file_exists path)

let test_remove_unregisters () =
  ensure_cleanup ();
  let path =
    require_path
      (Temp_file_guard.create ~prefix:"temp_guard_remove" ~suffix:".tmp" ())
  in
  check bool "file exists before remove" true (file_exists path);
  Temp_file_guard.remove path;
  check bool "file removed" false (file_exists path);
  (* cleanup should be a no-op now *)
  ensure_cleanup ()

let suite =
  [
    ("create files in system temp dir", `Quick, test_create_uses_system_temp);
    ("remove unregisters tracked files", `Quick, test_remove_unregisters);
  ]
