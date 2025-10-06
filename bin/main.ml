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

open! Base
open Stdio
open Chessmate

let usage_lines =
  [ "Usage: chessmate <command> [options]";
    "";
    "Commands:";
    "  ingest <pgn-file>   Parse a PGN and persist it using DATABASE_URL";
    "  query <question>    Send a natural-language question to the query API";
    "  help                Show this message" ]

let print_usage () = List.iter usage_lines ~f:(fun line -> printf "%s\n" line)

let exit_with_error err =
  eprintf "Error: %s\n" (Error.to_string_hum err);
  Stdlib.exit 1

let run_ingest path =
  match Ingest_command.run path with
  | Ok () -> ()
  | Error err -> exit_with_error err

let run_query parts =
  let question = String.concat ~sep:" " parts |> String.strip in
  match Search_command.run question with
  | Ok () -> ()
  | Error err -> exit_with_error err

let () =
  match Array.to_list Stdlib.Sys.argv with
  | _ :: ("help" | "--help" | "-h") :: _ -> print_usage ()
  | _ :: "ingest" :: [] -> exit_with_error (Error.of_string "ingest requires a PGN file path")
  | _ :: "ingest" :: path :: _ -> run_ingest path
  | _ :: "query" :: [] -> exit_with_error (Error.of_string "query requires a question to ask")
  | _ :: "query" :: question_parts -> run_query question_parts
  | _ :: [] -> print_usage ()
  | [] -> print_usage ()
  | _ ->
      print_usage ();
      Stdlib.exit 1
