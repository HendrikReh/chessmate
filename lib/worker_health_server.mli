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

module Metrics : sig
  type t = {
    processed : int;
    failed : int;
    jobs_per_min : float;
    chars_per_sec : float;
    queue_depth : int;
  }
end

val start :
  port:int ->
  summary:(unit -> Health.summary) ->
  metrics:(unit -> (Metrics.t, string) Result.t) ->
  (unit -> unit) Or_error.t
(** [start ~port ~summary ~metrics] launches an HTTP server exposing `/health`
    (JSON) and `/metrics` (Prometheus style). The returned function stops the
    server. *)
