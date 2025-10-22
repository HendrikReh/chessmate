open! Base

let files : (string, String.comparator_witness) Set.t ref =
  ref (Set.empty (module String))

let lock = Stdlib.Mutex.create ()

let with_lock f =
  Stdlib.Mutex.lock lock;
  match f () with
  | result ->
      Stdlib.Mutex.unlock lock;
      result
  | exception exn ->
      Stdlib.Mutex.unlock lock;
      raise exn

let cleanup_files () =
  let to_remove =
    with_lock (fun () ->
        let paths = !files in
        files := Set.empty (module String);
        paths)
  in
  Set.iter to_remove ~f:(fun path -> try Stdlib.Sys.remove path with _ -> ())

let cleanup_now = cleanup_files

let register path =
  if String.is_empty path then
    Or_error.error_string "Temp_file_guard.register: empty path"
  else (
    with_lock (fun () -> files := Set.add !files path);
    Or_error.return ())

let remove path =
  with_lock (fun () -> files := Set.remove !files path);
  try Stdlib.Sys.remove path with _ -> ()

let optional_signal f = try Some (f ()) with Invalid_argument _ -> None

let reinstall_default_and_raise signal =
  Stdlib.Sys.set_signal signal Stdlib.Sys.Signal_default;
  try ignore (Unix.kill (Unix.getpid ()) signal)
  with _ -> Stdlib.exit (128 + signal)

let install_signal_handler signal =
  let handler _signal =
    cleanup_files ();
    reinstall_default_and_raise signal
  in
  ignore (Stdlib.Sys.signal signal (Stdlib.Sys.Signal_handle handler))

let install_once () =
  let installed = ref false in
  fun () ->
    if not !installed then (
      installed := true;
      Stdlib.at_exit cleanup_files;
      List.iter
        (List.filter_map ~f:Fn.id
           [
             optional_signal (fun () -> Stdlib.Sys.sigint);
             optional_signal (fun () -> Stdlib.Sys.sigterm);
           ])
        ~f:install_signal_handler)

let ensure_initialized =
  let install = install_once () in
  fun () -> install ()

let create ?(prefix = "chessmate") ?(suffix = ".tmp") () =
  ensure_initialized ();
  let temp_dir = Stdlib.Filename.get_temp_dir_name () in
  match
    Or_error.try_with (fun () ->
        Stdlib.Filename.temp_file ~temp_dir prefix suffix)
  with
  | Error err -> Error err
  | Ok path -> (
      match register path with
      | Ok () -> Ok path
      | Error err ->
          (try Stdlib.Sys.remove path with _ -> ());
          Error err)
