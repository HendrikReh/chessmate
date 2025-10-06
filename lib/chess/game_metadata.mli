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

(** Types summarizing chess game metadata. *)

type player = {
  name : string;
  fide_id : string option;
  rating : int option;
}

type t = {
  event : string option;
  site : string option;
  date : string option;
  round : string option;
  white : player;
  black : player;
  eco_code : string option;
  opening_name : string option;
  opening_slug : string option;
  result : string option;
}

val empty_player : player
val empty : t
val of_headers : (string * string) list -> t
