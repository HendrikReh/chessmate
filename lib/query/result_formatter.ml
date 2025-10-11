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

(** Assemble ranked results into human-readable summaries for the CLI and rich
    JSON payloads for the HTTP API. *)

open! Base

type game_ref = {
  game_id : int;
  white : string;
  black : string;
  score : float;
}

let summarize games =
  let count = Int.min 5 (List.length games) in
  let top_games = List.take games count in
  top_games
  |> List.map ~f:(fun g ->
         Printf.sprintf "#%d %s vs %s (score %.2f)" g.game_id g.white g.black g.score)
  |> String.concat ~sep:"\n"
