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

(** Translates parsed PGNs into per-ply FEN snapshots and move annotations. *)

open! Base

val fens_of_string : string -> string list Or_error.t
(** [fens_of_string pgn] parses [pgn] (single game, mainline only) and returns
    the list of FEN strings after each half-move. *)

val fens_of_file : string -> string list Or_error.t
(** Convenience wrapper that reads the given PGN file and delegates to
    [fens_of_string]. *)

val fen_after_move :
  string ->
  color:[ `White | `Black ] ->
  move_number:int ->
  string Or_error.t
(** [fen_after_move pgn ~color ~move_number] returns the FEN string immediately
    after the specified player's move number. For example, passing
    [~color:`Black ~move_number:39] yields the FEN after Black's 39th move.
    Returns an error if the PGN does not contain that move. *)
