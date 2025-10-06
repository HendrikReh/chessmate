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

(** PGN parsing and normalization utilities. *)

type move = {
  san : string;
  turn : int;
  ply : int;
}

(** Parsed PGN artifact with metadata headers and SAN moves. *)
type t = {
  headers : (string * string) list;
  moves : move list;
}

val parse : string -> t Or_error.t

val ply_count : t -> int
val white_name : t -> string option
val black_name : t -> string option
val white_rating : t -> int option
val black_rating : t -> int option
val event : t -> string option
val site : t -> string option
val round : t -> string option
val result : t -> string option
val event_date : t -> string option
val white_move : t -> int -> move option
val black_move : t -> int -> move option
val tag_value : t -> string -> string option
