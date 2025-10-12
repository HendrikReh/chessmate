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

(** Implement the `chessmate ingest` command: parse PGNs, enforce queue guard
    rails, and persist games plus embedding jobs. *)

open! Base
open Stdio

let ( let* ) t f = Or_error.bind t ~f

type stats = { inserted : int; skipped : int }

let empty_stats = { inserted = 0; skipped = 0 }
let default_pending_limit = 250_000
let default_worker_count = 4

let pending_guard_limit () =
  Config.Cli.pending_guard_limit ~default:default_pending_limit

let preview raw =
  let condensed = String.strip raw in
  if String.length condensed <= 100 then condensed
  else String.prefix condensed 100 ^ "…"

let log_skip index reason raw =
  eprintf "Skipping PGN #%d: %s\n" index reason;
  eprintf "  Preview: %s\n" (preview raw)

let enforce_pending_guard repo = function
  | None -> Or_error.return ()
  | Some limit ->
      let* pending = Repo_postgres.pending_embedding_job_count repo in
      if Int.(pending >= limit) then
        Or_error.errorf
          "Pending embedding queue has %d jobs which meets or exceeds the \
           guard limit (%d). Aborting ingest. Set \
           CHESSMATE_MAX_PENDING_EMBEDDINGS to raise or <= 0 to disable."
          pending limit
      else (
        if Int.(pending > 0) then
          eprintf
            "Embedding queue currently has %d pending jobs (limit %d). \
             Proceeding with ingest.\n"
            pending limit;
        Or_error.return ())

let run path =
  if not (Stdlib.Sys.file_exists path) then
    Or_error.errorf "PGN file %s does not exist" path
  else
    let contents = In_channel.read_all path in
    let* concurrency =
      Cli_common.positive_int_from_env ~name:"CHESSMATE_INGEST_CONCURRENCY"
        ~default:default_worker_count
    in
    pending_guard_limit ()
    |> Or_error.bind ~f:(fun guard ->
           Cli_common.with_db_url (fun url ->
               let* repo = Repo_postgres.create url in
               let* () = enforce_pending_guard repo guard in
               let stats = ref empty_stats in
               let mutex = Lwt_mutex.create () in
               eprintf "Using ingest concurrency %d\n%!" concurrency;
               let on_error ~index ~raw err =
                 Lwt_mutex.with_lock mutex (fun () ->
                     log_skip index (Error.to_string_hum err) raw;
                     stats := { !stats with skipped = !stats.skipped + 1 };
                     Lwt.return ())
               in
               let queue =
                 Lwt_pool.create concurrency (fun () -> Lwt.return_unit)
               in
               let process_game ~index ~raw game =
                 Lwt_pool.use queue (fun () ->
                     let metadata =
                       Game_metadata.of_headers game.Pgn_parser.headers
                     in
                     match
                       Repo_postgres.insert_game repo ~metadata ~pgn:raw
                         ~moves:game.moves
                     with
                     | Ok (game_id, position_count) ->
                         Lwt_mutex.with_lock mutex (fun () ->
                             printf
                               "Stored game %d (PGN #%d) with %d positions\n"
                               game_id index position_count;
                             stats :=
                               { !stats with inserted = !stats.inserted + 1 };
                             Lwt.return_unit)
                     | Error err -> on_error ~index ~raw err)
               in
               Lwt_main.run
                 (Pgn_parser.stream_games contents ~on_error ~f:process_game);
               if Int.equal !stats.inserted 0 then
                 Or_error.error_string
                   "No games ingested; see skipped entries above."
               else (
                 printf "Ingest complete: %d stored, %d skipped.\n"
                   !stats.inserted !stats.skipped;
                 Or_error.return ())))
