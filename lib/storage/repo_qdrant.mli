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

(** Minimal Qdrant client for upserting and searching chess position vectors. *)

open! Base

type point = {
  id : string;
  vector : float list;
  payload : Yojson.Safe.t;
}

type scored_point = {
  id : string;
  score : float;
  payload : Yojson.Safe.t option;
}

val upsert_points : point list -> unit Or_error.t
(** Upsert a batch of points into the configured collection. *)

val vector_search :
  vector:float list ->
  filters:Yojson.Safe.t list option ->
  limit:int ->
  scored_point list Or_error.t
(** Perform a vector search returning scored points with payloads. *)

type test_hooks = {
  upsert : point list -> unit Or_error.t;
  search :
    vector:float list ->
    filters:Yojson.Safe.t list option ->
    limit:int ->
    scored_point list Or_error.t;
}

val with_test_hooks : test_hooks -> (unit -> 'a) -> 'a
(** Execute [f] with custom hooks for unit testing. Restores the previous hooks afterwards. *)
