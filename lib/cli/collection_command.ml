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

(** Implements `chessmate collection` sub-commands for managing Qdrant
    snapshots. The commands are thin wrappers around the HTTP API with local
    metadata journaling for audit and discovery. *)

open! Base
open Stdio
module Snapshot = Repo_qdrant
module Or_error = Base.Or_error

let default_log_path =
  Stdlib.Filename.concat "snapshots" "qdrant_snapshots.jsonl"

let env_log_path = "CHESSMATE_SNAPSHOT_LOG"

let resolve_log_path ?override () =
  match override with
  | Some explicit when not (String.is_empty (String.strip explicit)) -> explicit
  | _ -> (
      match Stdlib.Sys.getenv_opt env_log_path with
      | Some value when not (String.is_empty (String.strip value)) -> value
      | _ -> default_log_path)

let rec ensure_directory path =
  if String.equal path "." || String.equal path ".." || String.equal path ""
  then ()
  else if Stdlib.Sys.file_exists path then
    if Stdlib.Sys.is_directory path then ()
    else failwith (Printf.sprintf "%s exists but is not a directory" path)
  else (
    ensure_directory (Stdlib.Filename.dirname path);
    Unix.mkdir path 0o755)

let ensure_parent_directory file_path =
  let dir = Stdlib.Filename.dirname file_path in
  ensure_directory dir

let iso_timestamp_of_float seconds =
  let tm = Unix.gmtime seconds in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.tm_year + 1900)
    (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

let now_iso () = iso_timestamp_of_float (Unix.gettimeofday ())

type metadata_record = {
  snapshot : Snapshot.snapshot;
  recorded_at : string;
  note : string option;
}

let metadata_to_json record =
  let base =
    [
      ("name", `String record.snapshot.name);
      ("location", `String record.snapshot.location);
      ("created_at", `String record.snapshot.created_at);
      ("size_bytes", `Int record.snapshot.size_bytes);
      ("recorded_at", `String record.recorded_at);
    ]
  in
  let fields =
    match record.note with
    | Some note when not (String.is_empty (String.strip note)) ->
        ("note", `String note) :: base
    | _ -> base
  in
  `Assoc fields

let parse_int_field name json =
  match json with
  | `Int value -> Or_error.return value
  | `Float value -> Or_error.return (Float.to_int value)
  | other ->
      Or_error.errorf "snapshot field %s expected number, got %s" name
        (Yojson.Safe.to_string other)

let metadata_of_json json =
  let open Yojson.Safe.Util in
  let required_string field =
    match member field json with
    | `String value -> Or_error.return value
    | `Null -> Or_error.errorf "snapshot metadata missing %s" field
    | other ->
        Or_error.errorf "snapshot metadata field %s expected string, got %s"
          field
          (Yojson.Safe.to_string other)
  in
  let snapshot_field field = required_string field in
  let size_json = member "size_bytes" json in
  Or_error.bind (snapshot_field "name") ~f:(fun name ->
      Or_error.bind (snapshot_field "location") ~f:(fun location ->
          Or_error.bind (snapshot_field "created_at") ~f:(fun created_at ->
              Or_error.bind (parse_int_field "size_bytes" size_json)
                ~f:(fun size_bytes ->
                  Or_error.bind (required_string "recorded_at")
                    ~f:(fun recorded_at ->
                      let note = member "note" json |> to_string_option in
                      let snapshot =
                        Snapshot.{ name; location; created_at; size_bytes }
                      in
                      Or_error.return { snapshot; recorded_at; note })))))

let read_metadata path =
  if not (Stdlib.Sys.file_exists path) then Or_error.return []
  else
    let lines = In_channel.read_lines path in
    List.fold_result lines ~init:[] ~f:(fun acc line ->
        let trimmed = String.strip line in
        if String.is_empty trimmed then Or_error.return acc
        else
          try
            let json = Yojson.Safe.from_string trimmed in
            metadata_of_json json
            |> Or_error.map ~f:(fun record -> record :: acc)
          with Yojson.Json_error msg ->
            Or_error.errorf "failed to parse snapshot metadata: %s" msg)
    |> Or_error.map ~f:List.rev

let append_metadata path record =
  try
    ensure_parent_directory path;
    Out_channel.with_file ~append:true ~perm:0o644 path ~f:(fun oc ->
        Yojson.Safe.to_string (metadata_to_json record)
        |> Out_channel.output_string oc;
        Out_channel.newline oc);
    Or_error.return ()
  with exn ->
    Or_error.errorf "unable to append snapshot metadata: %s"
      (Stdlib.Printexc.to_string exn)

let describe_snapshot ?(prefix = "-") (snapshot : Snapshot.snapshot) =
  let size_mb = Float.of_int snapshot.size_bytes /. 1024. /. 1024. in
  printf "%s %s (%0.1f MiB) created %s\n    location: %s\n" prefix snapshot.name
    size_mb snapshot.created_at snapshot.location

let print_snapshot_result (snapshot : Snapshot.snapshot) ~log_path ~note =
  let recorded_at = now_iso () in
  let record = { snapshot; recorded_at; note } in
  (match append_metadata log_path record with
  | Ok () -> ()
  | Error err ->
      eprintf "Warning: failed to write snapshot log (%s)\n"
        (Error.to_string_hum err));
  printf "Snapshot created: %s\n" snapshot.name;
  describe_snapshot snapshot

let latest_snapshot_by_name entries ~name =
  entries |> List.rev
  |> List.find ~f:(fun record -> String.equal record.snapshot.name name)
  |> Option.map ~f:(fun record -> record.snapshot)

let choose_snapshot_location ~snapshot_name ~log_path =
  match read_metadata log_path with
  | Error err -> Error err
  | Ok entries -> (
      match latest_snapshot_by_name entries ~name:snapshot_name with
      | Some snapshot -> Or_error.return snapshot
      | None ->
          Snapshot.list_snapshots ()
          |> Or_error.bind ~f:(fun snapshots ->
                 match
                   List.find snapshots ~f:(fun (snap : Snapshot.snapshot) ->
                       String.equal snap.name snapshot_name)
                 with
                 | Some snapshot -> Or_error.return snapshot
                 | None ->
                     Or_error.errorf
                       "Snapshot %s not found locally or in Qdrant metadata"
                       snapshot_name))

let snapshot ?log_path ?note ?snapshot_name () =
  let log_path = resolve_log_path ?override:log_path () in
  Snapshot.create_snapshot ?snapshot_name ()
  |> Or_error.bind ~f:(fun snapshot ->
         print_snapshot_result snapshot ~log_path ~note;
         Or_error.return ())

let restore ?log_path ?snapshot_name ?location () =
  match (location, snapshot_name) with
  | None, None ->
      Or_error.error_string
        "restore requires either --snapshot <name> or --location <path>"
  | Some location, _ -> Snapshot.restore_snapshot ~location ()
  | None, Some name ->
      let log_path = resolve_log_path ?override:log_path () in
      choose_snapshot_location ~snapshot_name:name ~log_path
      |> Or_error.bind ~f:(fun snapshot ->
             Snapshot.restore_snapshot ~location:snapshot.Snapshot.location ())

let format_metadata entries =
  if List.is_empty entries then printf "No local snapshot metadata recorded.\n"
  else (
    printf "Recorded snapshots (newest last):\n";
    List.iter entries ~f:(fun entry ->
        let size_mb =
          Float.of_int entry.snapshot.size_bytes /. 1024. /. 1024.
        in
        let note_suffix =
          match entry.note with
          | None | Some "" -> ""
          | Some note -> Printf.sprintf " — %s" note
        in
        printf "- %s (%0.1f MiB) created %s, recorded %s%s\n    %s\n"
          entry.snapshot.name size_mb entry.snapshot.created_at
          entry.recorded_at note_suffix entry.snapshot.location))

let list ?log_path () =
  let log_path = resolve_log_path ?override:log_path () in
  let local =
    match read_metadata log_path with
    | Ok entries -> entries
    | Error err ->
        eprintf "Warning: failed to read snapshot log (%s)\n"
          (Error.to_string_hum err);
        []
  in
  (match Snapshot.list_snapshots () with
  | Error err ->
      eprintf "Warning: failed to fetch snapshots from Qdrant (%s)\n"
        (Error.to_string_hum err)
  | Ok snapshots ->
      if List.is_empty snapshots then
        printf "No snapshots reported by Qdrant.\n"
      else (
        printf "Snapshots reported by Qdrant:\n";
        List.iter snapshots ~f:(fun snapshot ->
            describe_snapshot ~prefix:"•" snapshot)));
  format_metadata local;
  Or_error.return ()
