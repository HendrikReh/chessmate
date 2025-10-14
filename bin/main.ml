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
  config                  Run configuration and dependency checks
  ingest <pgn-file>       Parse a PGN and persist it (requires DATABASE_URL)
  twic-precheck <pgn-file> Inspect a TWIC PGN and report malformed games
  query [--json] <question>
                          Send a natural-language question to the query API
  fen <pgn-file> [output] Emit FEN after each half-move (optional output file)
  embedding-worker        Placeholder (use `dune exec embedding_worker` for now)
  help                    Show this message
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

let parse_limit_flag value =
  let stripped = String.strip value in
  match Int.of_string_opt stripped with
  | None -> Or_error.error_string "limit must be an integer"
  | Some parsed ->
      if parsed < 1 then Or_error.error_string "limit must be >= 1"
      else if parsed > Query_intent.max_limit then
        Or_error.errorf "limit must be <= %d" Query_intent.max_limit
      else Or_error.return parsed

let parse_offset_flag value =
  let stripped = String.strip value in
  match Int.of_string_opt stripped with
  | None -> Or_error.error_string "offset must be an integer"
  | Some parsed ->
      if parsed < 0 then Or_error.error_string "offset must be >= 0"
      else Or_error.return parsed

type query_options = {
  as_json : bool;
  limit : int option;
  offset : int option;
  question : string;
}

let rec parse_query_parts as_json limit offset remaining =
  match remaining with
  | [] -> Or_error.error_string "query requires a question to ask"
  | "--json" :: rest -> parse_query_parts true limit offset rest
  | "--limit" :: [] -> Or_error.error_string "--limit expects a value"
  | "--limit" :: value :: rest -> (
      match parse_limit_flag value with
      | Ok parsed -> parse_query_parts as_json (Some parsed) offset rest
      | Error _ as err -> err)
  | "--offset" :: [] -> Or_error.error_string "--offset expects a value"
  | "--offset" :: value :: rest -> (
      match parse_offset_flag value with
      | Ok parsed -> parse_query_parts as_json limit (Some parsed) rest
      | Error _ as err -> err)
  | "--" :: rest ->
      let question = String.concat ~sep:" " rest |> String.strip in
      if String.is_empty question then
        Or_error.error_string "query requires a question to ask"
      else Or_error.return { as_json; limit; offset; question }
  | flag :: _ when String.is_prefix flag ~prefix:"--" ->
      Or_error.errorf "unknown flag %s" flag
  | remaining ->
      let question = String.concat ~sep:" " remaining |> String.strip in
      if String.is_empty question then
        Or_error.error_string "query requires a question to ask"
      else Or_error.return { as_json; limit; offset; question }

let run_query parts =
  match parse_query_parts false None None parts with
  | Error err -> exit_with_error err
  | Ok { as_json; limit; offset; question } -> (
      match Service_health.ensure_all () with
      | Error err -> exit_with_error err
      | Ok () -> (
          match Search_command.run ~as_json ?limit ?offset question with
          | Ok () -> ()
          | Error err -> exit_with_error err))

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

let run ?argv () =
  let argv = Option.value argv ~default:Stdlib.Sys.argv in
  match Array.to_list argv with
  | [] | [ _ ] -> print_usage ()
  | _ :: rest -> (
      let rest = strip_dune_exec rest in
      match rest with
      | ("help" | "--help" | "-h") :: _ -> print_usage ()
      | "config" :: _ -> Config_command.run ()
      | "ingest" :: [] ->
          exit_with_error (Error.of_string "ingest requires a PGN file path")
      | "ingest" :: path :: _ -> run_ingest path
      | "twic-precheck" :: [] ->
          exit_with_error
            (Error.of_string "twic-precheck requires a PGN file path")
      | "twic-precheck" :: path :: _ -> run_twic_precheck path
      | "query" :: args -> run_query args
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

let () = run ()
