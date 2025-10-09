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

(** Utilities for parsing, validating, and manipulating FEN strings. *)

open! Base

type t = string

val normalize : t -> t Or_error.t
(** Normalize and validate a FEN string.

    Ensures that the FEN string contains exactly six space-separated fields,
    validates the board layout, and enforces chess rules such as one king per
    side, pawns not appearing on the first or eighth rank, legal castling
    availability, consistent en passant squares, and well-formed move counters.
    On success the returned string is trimmed and normalized to use single
    spaces between fields. *)

val hash : t -> string
(** Stable hash for storing deduplicated positions. *)
