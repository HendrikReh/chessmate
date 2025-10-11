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

(* Entry point for the `chessmate` CLI, wiring subcommands and environment bootstrapping. *)

open! Base
open Stdio
open Chessmate

let usage =
  {|
Usage: chessmate <command> [options]

Commands:
  ingest <pgn-file>        Parse a PGN and persist it (requires DATABASE_URL)
  twic-precheck <pgn-file> Inspect a TWIC PGN and report malformed games
  query [--json] <question>
                          Send a natural-language question to the query API
  fen <pgn-file> [output]  Emit FEN after each half-move (optional output file)
  embedding-worker         Placeholder (use `dune exec embedding_worker` for now)
  help                     Show this message
|}

let print_usage () = printf "%s\n" usage

let exit_with_error err =
  eprintf "Error: %s\n" (Error.to_string_hum err);
  Stdlib.exit 1

let run_ingest path =
  match Ingest_command.run path with
  | Ok () -> ()
  | Error err -> exit_with_error err

let run_twic_precheck path =
  match Twic_precheck_command.run path with
  | Ok () -> ()
  | Error err -> exit_with_error err

let run_query parts ~as_json =
  let question = String.concat ~sep:" " parts |> String.strip in
  if String.is_empty question then
    exit_with_error (Error.of_string "query requires a question")
  else
    match Service_health.ensure_all () with
    | Error err -> exit_with_error err
    | Ok () -> (
        match Search_command.run ~as_json question with
        | Ok () -> ()
        | Error err -> exit_with_error err)

let run_fen parts =
  match parts with
  | [] -> exit_with_error (Error.of_string "fen requires a PGN file path")
  | [ input ] -> (
      match Pgn_to_fen_command.run ~input ~output:None with
      | Ok () -> ()
      | Error err -> exit_with_error err)
  | input :: output :: _ -> (
      match Pgn_to_fen_command.run ~input ~output:(Some output) with
      | Ok () -> ()
      | Error err -> exit_with_error err)

let strip_dune_exec = function
  | [] -> []
  | first :: rest when String.equal first "--" -> rest
  | list -> list

let () =
  match Array.to_list Stdlib.Sys.argv with
  | _ :: [] -> print_usage ()
  | [] -> print_usage ()
  | _ :: rest -> (
      let rest = strip_dune_exec rest in
      match rest with
      | ("help" | "--help" | "-h") :: _ -> print_usage ()
      | "ingest" :: [] ->
          exit_with_error (Error.of_string "ingest requires a PGN file path")
      | "ingest" :: path :: _ -> run_ingest path
      | "twic-precheck" :: [] ->
          exit_with_error
            (Error.of_string "twic-precheck requires a PGN file path")
      | "twic-precheck" :: path :: _ -> run_twic_precheck path
      | "query" :: [] ->
          exit_with_error (Error.of_string "query requires a question to ask")
      | "query" :: "--json" :: question_parts ->
          run_query question_parts ~as_json:true
      | "query" :: question_parts -> run_query question_parts ~as_json:false
      | "fen" :: args -> run_fen args
      | "embedding-worker" :: _ ->
          exit_with_error
            (Error.of_string
               "embedding-worker command not yet wired; use dune exec \
                embedding_worker")
      | [] -> print_usage ()
      | _ ->
          print_usage ();
          Stdlib.exit 1)
