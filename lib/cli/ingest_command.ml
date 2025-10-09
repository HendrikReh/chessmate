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

type stats = {
  inserted : int;
  skipped : int;
}

let empty_stats = { inserted = 0; skipped = 0 }

let default_pending_limit = 250_000

let ( let* ) t f = Or_error.bind t ~f

let pending_guard_limit () =
  Config.Cli.pending_guard_limit ~default:default_pending_limit

let preview raw =
  let condensed = String.strip raw in
  if String.length condensed <= 100 then condensed else String.prefix condensed 100 ^ "…"

let log_skip index reason raw =
  eprintf "Skipping PGN #%d: %s\n" index reason;
  eprintf "  Preview: %s\n" (preview raw)

let enforce_pending_guard repo = function
  | None -> Or_error.return ()
  | Some limit ->
      let* pending = Repo_postgres.pending_embedding_job_count repo in
      if Int.(pending >= limit) then
        Or_error.errorf
          "Pending embedding queue has %d jobs which meets or exceeds the guard limit (%d). Aborting ingest. Set CHESSMATE_MAX_PENDING_EMBEDDINGS to raise or <= 0 to disable."
          pending
          limit
      else (
        if Int.(pending > 0) then
          eprintf "Embedding queue currently has %d pending jobs (limit %d). Proceeding with ingest.\n" pending limit;
        Or_error.return () )

let run path =
  if not (Stdlib.Sys.file_exists path) then
    Or_error.errorf "PGN file %s does not exist" path
  else
    let contents = In_channel.read_all path in
    pending_guard_limit ()
    |> Or_error.bind ~f:(fun guard ->
           Cli_common.with_db_url (fun url ->
               let* repo = Repo_postgres.create url in
               let* () = enforce_pending_guard repo guard in
               let ingest stats ~index ~raw game =
                 let metadata = Game_metadata.of_headers game.Pgn_parser.headers in
                 match Repo_postgres.insert_game repo ~metadata ~pgn:raw ~moves:game.moves with
                 | Ok (game_id, position_count) ->
                     printf "Stored game %d (PGN #%d) with %d positions\n" game_id index position_count;
                     Or_error.return { stats with inserted = stats.inserted + 1 }
                 | Error err ->
                     log_skip index (Error.to_string_hum err) raw;
                     Or_error.return { stats with skipped = stats.skipped + 1 }
               in
               let on_error stats ~index ~raw err =
                 log_skip index (Error.to_string_hum err) raw;
                 Or_error.return { stats with skipped = stats.skipped + 1 }
               in
               Pgn_parser.fold_games ~on_error contents ~init:empty_stats ~f:ingest
               |> Or_error.bind ~f:(fun stats ->
                      if Int.equal stats.inserted 0 then
                        Or_error.error_string "No games ingested; see skipped entries above."
                      else (
                        printf "Ingest complete: %d stored, %d skipped.\n"
                          stats.inserted stats.skipped;
                        Or_error.return ();
                      ))
           ))
