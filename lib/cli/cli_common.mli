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

(** Shared CLI helpers for environment setup, logging, and error reporting. *)

open! Base

val with_db_url : (string -> 'a Or_error.t) -> 'a Or_error.t
(** Fetch [DATABASE_URL] via {!Config.Cli.database_url} and apply the provided function. *)

val api_base_url : unit -> string
(** Resolve the query API base URL via {!Config.Cli.api_base_url}. *)
