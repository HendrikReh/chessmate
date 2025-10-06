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

type rating_filter = {
  white_min : int option;
  black_max_delta : int option;
}

type request = {
  text : string;
}

type plan = {
  filters : (string * string) list;
  rating : rating_filter;
}

let analyse request =
  let lowered = String.lowercase request.text in
  let filters =
    [
      ( if String.is_substring lowered ~substring:"kings indian" then
          Some ("opening", "kings_indian_defense")
        else
          None
      );
      ( if String.is_substring lowered ~substring:"queenside majority" then
          Some ("theme", "queenside_majority")
        else
          None
      );
    ]
    |> List.filter_map ~f:Fn.id
  in
  let rating =
    let white_min =
      if String.is_substring lowered ~substring:"white" && String.is_substring lowered ~substring:"2500"
      then Some 2500
      else None
    in
    let black_delta =
      if String.is_substring lowered ~substring:"100 points lower" then Some 100 else None
    in
    { white_min; black_max_delta = black_delta }
  in
  { filters; rating }
