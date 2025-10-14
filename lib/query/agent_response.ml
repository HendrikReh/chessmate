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

(** Parse the GPT-5 agent JSON payload into typed evaluation items consumed by
    the planner and formatter. *)

module Util = Yojson.Safe.Util

type item = {
  game_id : int;
  score : float;
  explanation : string option;
  themes : string list;
}

let parse content =
  try
    let json = Yojson.Safe.from_string content in
    let open Util in
    let items = json |> member "evaluations" |> to_list in
    let parse_item item =
      match
        ( member "game_id" item |> to_int_option,
          member "score" item |> to_float_option )
      with
      | Some game_id, Some score ->
          let explanation = member "explanation" item |> to_string_option in
          let themes =
            match member "themes" item with
            | `Null -> []
            | json_themes ->
                json_themes |> to_list |> List.filter_map ~f:to_string_option
          in
          Some { game_id; score; explanation; themes }
      | _ -> None
    in
    items |> List.filter_map ~f:parse_item |> Or_error.return
  with Yojson.Json_error msg | Util.Type_error (msg, _) ->
    Or_error.error_string msg
