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
Usage: chessmate [options] <command> [command-args]

Options:
  --listen-prometheus=<port>
                          Expose Prometheus metrics at http://localhost:<port>/metrics

Commands:
  config                  Run configuration and dependency checks
  ingest <pgn-file>       Parse a PGN and persist it (requires DATABASE_URL)
  twic-precheck <pgn-file> Inspect a TWIC PGN and report malformed games
  query [--json] <question>
                          Send a natural-language question to the query API
  fen <pgn-file> [output] Emit FEN after each half-move (optional output file)
  collection snapshot --name <name> [--note TEXT]
                          Create a Qdrant snapshot and log metadata locally
  collection restore (--snapshot <name> | --location <path>)
                          Restore Qdrant collection using a recorded snapshot
  collection list         Show snapshots known to Qdrant and the local log
  embedding-worker        Placeholder (use `dune exec embedding_worker` for now)
  help                    Show this message
|}

let print_usage () = printf "%s\n" usage

let exit_with_error err =
  eprintf "Error: %s\n" (Error.to_string_hum err);
  Stdlib.exit 1

let parse_listen_prometheus_flag args =
  let rec loop seen_port acc = function
    | [] -> Or_error.return (seen_port, List.rev acc)
    | "--listen-prometheus" :: [] ->
        Or_error.error_string "--listen-prometheus expects a port value"
    | "--listen-prometheus" :: value :: rest -> (
        if Option.is_some seen_port then
          Or_error.error_string "--listen-prometheus supplied more than once"
        else
          match parse_port_value value with
          | Error _ as err -> err
          | Ok port -> loop (Some port) acc rest)
    | arg :: rest when String.is_prefix arg ~prefix:"--listen-prometheus=" -> (
        if Option.is_some seen_port then
          Or_error.error_string "--listen-prometheus supplied more than once"
        else
          let value =
            String.drop_prefix arg (String.length "--listen-prometheus=")
          in
          match parse_port_value value with
          | Error _ as err -> err
          | Ok port -> loop (Some port) acc rest)
    | arg :: rest -> loop seen_port (arg :: acc) rest
  and parse_port_value raw =
    match Int.of_string raw with
    | exception _ ->
        Or_error.errorf "Invalid Prometheus port '%s' (expected integer)" raw
    | port when port < 1 || port > 65_535 ->
        Or_error.errorf "Invalid Prometheus port %d (expected 1-65535)" port
    | port -> Or_error.return port
  in
  loop None [] args

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

type snapshot_cli_args = {
  name : string option;
  note : string option;
  log_path : string option;
}

type restore_cli_args = {
  snapshot : string option;
  location : string option;
  log_path : string option;
}

type list_cli_args = { log_path : string option }

let rec parse_collection_snapshot (acc : snapshot_cli_args) = function
  | [] -> (
      let { name; note; log_path } = acc in
      match name with
      | None -> Or_error.error_string "collection snapshot requires --name"
      | Some snapshot_name ->
          Collection_command.snapshot ?log_path ?note ~snapshot_name ())
  | "--name" :: [] -> Or_error.error_string "--name expects a value"
  | "--name" :: value :: rest ->
      parse_collection_snapshot
        { acc with name = Some (String.strip value) }
        rest
  | "--note" :: [] -> Or_error.error_string "--note expects a value"
  | "--note" :: value :: rest ->
      parse_collection_snapshot { acc with note = Some value } rest
  | "--log-path" :: [] -> Or_error.error_string "--log-path expects a value"
  | "--log-path" :: value :: rest ->
      parse_collection_snapshot { acc with log_path = Some value } rest
  | flag :: _ -> Or_error.errorf "unknown collection snapshot flag %s" flag

and parse_collection_restore (acc : restore_cli_args) = function
  | [] ->
      Collection_command.restore ?log_path:acc.log_path
        ?snapshot_name:acc.snapshot ?location:acc.location ()
  | "--snapshot" :: [] -> Or_error.error_string "--snapshot expects a value"
  | "--snapshot" :: value :: rest ->
      parse_collection_restore
        { acc with snapshot = Some (String.strip value) }
        rest
  | "--location" :: [] -> Or_error.error_string "--location expects a value"
  | "--location" :: value :: rest ->
      parse_collection_restore { acc with location = Some value } rest
  | "--log-path" :: [] -> Or_error.error_string "--log-path expects a value"
  | "--log-path" :: value :: rest ->
      parse_collection_restore { acc with log_path = Some value } rest
  | flag :: _ -> Or_error.errorf "unknown collection restore flag %s" flag

and parse_collection_list (acc : list_cli_args) = function
  | [] -> Collection_command.list ?log_path:acc.log_path ()
  | "--log-path" :: [] -> Or_error.error_string "--log-path expects a value"
  | "--log-path" :: value :: rest ->
      let next : list_cli_args = { log_path = Some value } in
      parse_collection_list next rest
  | flag :: _ -> Or_error.errorf "unknown collection list flag %s" flag

and run_collection args =
  let result : unit Or_error.t =
    match args with
    | [] -> Or_error.error_string "collection command requires a subcommand"
    | sub :: rest -> (
        match sub with
        | "snapshot" ->
            let init : snapshot_cli_args =
              { name = None; note = None; log_path = None }
            in
            parse_collection_snapshot init rest
        | "restore" ->
            let init = { snapshot = None; location = None; log_path = None } in
            parse_collection_restore init rest
        | "list" ->
            let init : list_cli_args = { log_path = None } in
            parse_collection_list init rest
        | other -> Or_error.errorf "unknown collection subcommand %s" other)
  in
  match result with Ok () -> () | Error err -> exit_with_error err

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
      match parse_listen_prometheus_flag rest with
      | Error err -> exit_with_error err
      | Ok (flag_port, args) -> (
          match Cli_common.prometheus_port_from_env () with
          | Error err -> exit_with_error err
          | Ok env_port -> (
              let effective_port =
                match flag_port with Some _ -> flag_port | None -> env_port
              in
              let () =
                match Metrics_http.start_if_configured ~port:effective_port with
                | Error err -> exit_with_error err
                | Ok exporter ->
                    Option.iter exporter ~f:(fun server ->
                        Stdlib.at_exit (fun () -> Metrics_http.stop server))
              in
              match args with
              | ("help" | "--help" | "-h") :: _ -> print_usage ()
              | "config" :: _ -> Config_command.run ()
              | "ingest" :: [] ->
                  exit_with_error
                    (Error.of_string "ingest requires a PGN file path")
              | "ingest" :: path :: _ -> run_ingest path
              | "twic-precheck" :: [] ->
                  exit_with_error
                    (Error.of_string "twic-precheck requires a PGN file path")
              | "twic-precheck" :: path :: _ -> run_twic_precheck path
              | "query" :: args -> run_query args
              | "fen" :: args -> run_fen args
              | "collection" :: args -> run_collection args
              | "embedding-worker" :: _ ->
                  exit_with_error
                    (Error.of_string
                       "embedding-worker command not yet wired; use dune exec \
                        embedding_worker")
              | [] -> print_usage ()
              | _ ->
                  print_usage ();
                  Stdlib.exit 1)))

let () = run ()
