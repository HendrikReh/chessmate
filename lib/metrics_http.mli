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

type t

val start : port:int -> t Or_error.t
(** Start a Prometheus HTTP exporter on the provided [port]. *)

val start_if_configured : port:int option -> t option Or_error.t
(** Convenience helper returning [Ok None] when no port is supplied. *)

val stop : t -> unit
(** Stop the exporter and release resources. Safe to call multiple times. *)

val stop_opt : t option -> unit
(** [stop_opt] is a no-op when given [None]. *)
