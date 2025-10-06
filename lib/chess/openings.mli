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

(** Canonical opening metadata backed by ECO ranges. *)

type entry

val all : entry list
(** Entire opening catalogue. *)

val canonical_name_of_eco : string -> string option
(** [canonical_name_of_eco eco] resolves [eco] (e.g. "E60") to a canonical opening
    name if the ECO code is covered by the catalogue. *)

val slug_of_eco : string -> string option
(** Slug (lowercase, underscore) for the [eco] family. *)

val slugify : string -> string
(** Slugify an opening name for storage/filtering. *)

val filters_for_text : string -> (string * string) list
(** Build metadata filters for the given lowercased, punctuation-stripped text. *)
