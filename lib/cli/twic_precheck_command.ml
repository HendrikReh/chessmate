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

(* CLI command that validates TWIC PGN archives before ingestion. *)

open! Base
open Stdio

module Issue = struct
  type t = {
    index : int;
    problems : string list;
    hints : string list;
    preview : string option;
  }

  let create ?preview ~index problems hints =
    { index; problems; hints; preview }

  let print t =
    printf "\nPGN #%d\n" t.index;
    Option.iter t.preview ~f:(fun snippet -> printf "  Preview: %s\n" snippet);
    let combined = List.zip_exn t.problems t.hints in
    List.iter combined ~f:(fun (problem, hint) ->
        printf "  - Issue: %s\n    Fix: %s\n" problem hint)
end

let truncate_preview raw =
  let condensed = String.strip raw in
  if String.length condensed <= 80 then condensed
  else String.prefix condensed 80 ^ "…"

let validate_parsed_game index raw (game : Pgn_parser.t) =
  let problems = ref [] in
  let hints = ref [] in
  if List.is_empty game.moves then begin
    problems := "No moves detected" :: !problems;
    hints := "Remove the block or ensure the move list is present." :: !hints
  end;
  (match Pgn_parser.result game with
  | None ->
      problems := "Missing [Result] tag" :: !problems;
      hints :=
        "Add a [Result \"1-0\"/\"0-1\"/\"1/2-1/2\" or \"*\"] tag before the moves." :: !hints
  | Some result when not (List.mem Pgn_parser.default_valid_results result ~equal:String.equal) ->
      problems := Printf.sprintf "Unexpected result token '%s'" result :: !problems;
      hints := "Use one of 1-0, 0-1, 1/2-1/2, or *." :: !hints
  | Some _ -> ());
  if List.is_empty !problems then None
  else
    let preview = Some (truncate_preview raw) in
    Some (Issue.create ?preview ~index (List.rev !problems) (List.rev !hints))

let run path =
  if not (Stdlib.Sys.file_exists path) then
    Or_error.errorf "PGN file %s does not exist" path
  else
    let contents = In_channel.read_all path in
    let collect acc ~index ~raw game =
      match validate_parsed_game index raw game with
      | None -> Or_error.return acc
      | Some issue -> Or_error.return (issue :: acc)
    in
    let on_error acc ~index ~raw err =
      let problem = Printf.sprintf "Parse error: %s" (Error.to_string_hum err) in
      let hint = "Clean up or remove this entry (often a TWIC editorial note)." in
      let preview = Some (truncate_preview raw) in
      Or_error.return (Issue.create ?preview ~index [ problem ] [ hint ] :: acc)
    in
    match Pgn_parser.fold_games ~on_error contents ~init:[] ~f:collect with
    | Error err -> Or_error.errorf "Precheck aborted: %s" (Error.to_string_hum err)
    | Ok issues ->
        let issues = List.rev issues in
        if List.is_empty issues then (
          printf "No issues detected in %s.\n" path;
          Or_error.return ())
        else (
          printf "Found %d potential issue(s) in %s:\n" (List.length issues) path;
          List.iter issues ~f:Issue.print;
          printf "\nReview the fixes above before ingesting.\n";
          Or_error.return ())
