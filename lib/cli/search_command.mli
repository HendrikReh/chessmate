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

(** Implements the `chessmate query` CLI command. *)

open! Base

(** CLI entry point for querying the `/query` HTTP API (backed by the prototype
    planning pipeline). *)

val run :
  ?as_json:bool -> ?limit:int -> ?offset:int -> string -> unit Or_error.t
(** [run ?as_json question] posts [question] to the query API resolved by
    [CHESSMATE_API_URL]. When [as_json] is [true], the raw JSON body returned by
    the service is printed; otherwise a human-readable summary is rendered. *)
