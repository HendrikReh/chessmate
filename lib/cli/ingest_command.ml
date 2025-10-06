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

let run path =
  if not (Stdlib.Sys.file_exists path) then
    Or_error.errorf "PGN file %s does not exist" path
  else
    let contents = In_channel.read_all path in
    match Pgn_parser.parse contents with
    | Error err -> Or_error.errorf "Failed to parse PGN: %s" (Error.to_string_hum err)
    | Ok parsed ->
        let metadata = Game_metadata.of_headers parsed.headers in
        Cli_common.with_db_url (fun url ->
            match Repo_postgres.create url with
            | Error err -> Error err
            | Ok repo ->
                (match Repo_postgres.insert_game repo ~metadata ~pgn:contents ~moves:parsed.moves with
                | Ok (game_id, position_count) ->
                    printf "Stored game %d with %d positions\n" game_id position_count;
                    Or_error.return ()
                | Error err -> Error err))
