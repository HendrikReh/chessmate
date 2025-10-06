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

(** Wrapper around Qdrant HTTP API. *)

type t

type point_id = string

val create : string -> t Or_error.t
(** Create a client targeting the provided base URL. *)

val upsert_point :
  t ->
  point_id ->
  vector:float array ->
  payload:(string * string) list ->
  unit Or_error.t
(** Upsert a single point. Currently a stub returning an error. *)
