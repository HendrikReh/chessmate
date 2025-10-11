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

(** Lightweight in-memory cache for already-computed embeddings, primarily for
    tests and local development. *)

type t
(** Simple in-memory cache keyed by FEN. *)

val create : unit -> t [@@ocaml.doc "Initialise an empty cache."]

val find : t -> string -> float array option
[@@ocaml.doc "Retrieve a cached embedding (keyed by FEN)."]

val add : t -> string -> float array -> unit
[@@ocaml.doc "Store a computed embedding in the cache."]
