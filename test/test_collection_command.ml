open! Base
open Alcotest
open Chessmate

let with_temp_log f =
  let path = Filename.temp_file "chessmate" ".jsonl" in
  (try Stdlib.Sys.remove path with _ -> ());
  Exn.protect
    ~f:(fun () -> f path)
    ~finally:(fun () ->
      if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path)

let test_snapshot_writes_metadata () =
  with_temp_log (fun log_path ->
      let created_snapshots = ref [] in
      let snapshot_hook ~collection:_ ~snapshot_name =
        let name = Option.value snapshot_name ~default:"auto" in
        let snapshot =
          Repo_qdrant.
            {
              name;
              location = "/var/lib/qdrant/snapshots/" ^ name ^ ".snapshot";
              created_at = "2025-10-15T10:00:00Z";
              size_bytes = 1_048_576;
            }
        in
        created_snapshots := snapshot :: !created_snapshots;
        Or_error.return snapshot
      in
      let hooks =
        {
          Repo_qdrant.upsert = (fun _ -> Or_error.return ());
          search = (fun ~vector:_ ~filters:_ ~limit:_ -> Or_error.return []);
          create_snapshot = snapshot_hook;
          list_snapshots = (fun ~collection:_ -> Or_error.return []);
          restore_snapshot =
            (fun ~collection:_ ~location:_ -> Or_error.return ());
        }
      in
      Repo_qdrant.with_test_hooks hooks (fun () ->
          match
            Collection_command.snapshot ~log_path ~note:"pre-reindex"
              ~snapshot_name:"nightly-backup" ()
          with
          | Error err ->
              failf "snapshot command failed: %s" (Error.to_string_hum err)
          | Ok () ->
              (match !created_snapshots with
              | [ snapshot ] ->
                  check string "snapshot name" "nightly-backup" snapshot.name
              | _ -> fail "snapshot hook was not invoked exactly once");
              let lines = Stdio.In_channel.read_lines log_path in
              check int "metadata lines" 1 (List.length lines);
              let json = Yojson.Safe.from_string (List.hd_exn lines) in
              let open Yojson.Safe.Util in
              check string "logged name" "nightly-backup"
                (json |> member "name" |> to_string);
              check string "logged note" "pre-reindex"
                (json |> member "note" |> to_string)))

let test_restore_uses_log () =
  with_temp_log (fun log_path ->
      let restored = ref [] in
      let hook_snapshot ~collection:_ ~snapshot_name =
        let name = Option.value snapshot_name ~default:"auto" in
        let snapshot =
          Repo_qdrant.
            {
              name;
              location = "/var/lib/qdrant/snapshots/" ^ name ^ ".snapshot";
              created_at = "2025-10-15T11:00:00Z";
              size_bytes = 2_097_152;
            }
        in
        Or_error.return snapshot
      in
      let hooks =
        {
          Repo_qdrant.upsert = (fun _ -> Or_error.return ());
          search = (fun ~vector:_ ~filters:_ ~limit:_ -> Or_error.return []);
          create_snapshot = hook_snapshot;
          list_snapshots = (fun ~collection:_ -> Or_error.return []);
          restore_snapshot =
            (fun ~collection:_ ~location ->
              restored := (collection, location) :: !restored;
              Or_error.return ());
        }
      in
      Repo_qdrant.with_test_hooks hooks (fun () ->
          let snap_name = "rollback-checkpoint" in
          (match
             Collection_command.snapshot ~log_path ~snapshot_name:snap_name ()
           with
          | Ok () -> ()
          | Error err ->
              failf "snapshot precondition failed: %s" (Error.to_string_hum err));
          match
            Collection_command.restore ~log_path ~snapshot_name:snap_name ()
          with
          | Error err -> failf "restore failed: %s" (Error.to_string_hum err)
          | Ok () -> (
              match !restored with
              | [ (collection, location) ] ->
                  check string "collection" "positions" collection;
                  check string "location"
                    "/var/lib/qdrant/snapshots/rollback-checkpoint.snapshot"
                    location
              | _ -> fail "restore hook not invoked exactly once")))

let suite =
  [
    ("snapshot command writes metadata", `Quick, test_snapshot_writes_metadata);
    ("restore resolves snapshot from log", `Quick, test_restore_uses_log);
  ]
