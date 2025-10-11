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

(** CLI command that converts PGNs into streams of FEN positions. *)

open! Base

val run : input:string -> output:string option -> unit Or_error.t
(** [run ~input ~output] reads the PGN at [input], converts each half-move to a
    FEN string via [Pgn_to_fen], and either prints them (when [output=None]) or
    writes them to [output] (overwriting the file). *)
