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

(** Opium HTTP service exposing query endpoints and operational routes. *)

open! Base

val routes : Opium.App.t
(** Complete Opium application with rate limiting, health, metrics, and query
    routes. *)

val run_with_shutdown : Opium.App.t -> unit
(** Run the application while handling termination signals for graceful
    shutdown. *)

val run : unit -> unit
(** Start the Chessmate API service using configuration derived from the
    environment. *)
