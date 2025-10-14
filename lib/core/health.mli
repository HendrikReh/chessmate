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

type probe_result =
  [ `Ok of string option | `Error of string | `Skipped of string ]

type check_state =
  | Healthy of string option
  | Unhealthy of string
  | Skipped of string

type check = {
  name : string;
  required : bool;
  latency_ms : float option;
  state : check_state;
}

type summary_status = [ `Ok | `Degraded | `Error ]
type summary = { status : summary_status; checks : check list }

val summary_to_yojson : summary -> Yojson.Safe.t
val http_status_of : summary_status -> Cohttp.Code.status

module Test_hooks : sig
  type overrides = {
    postgres : (unit -> probe_result) option;
    qdrant : (unit -> probe_result) option;
    redis : (unit -> probe_result) option;
    openai : (unit -> probe_result) option;
    embeddings : (unit -> probe_result) option;
  }

  val empty : overrides
  val with_overrides : overrides -> f:(unit -> 'a) -> 'a
end

module Api : sig
  val summary :
    ?postgres:Repo_postgres.t Or_error.t Lazy.t ->
    config:Config.Api.t ->
    unit ->
    summary
end

module Worker : sig
  val summary :
    ?postgres:Repo_postgres.t Or_error.t Lazy.t ->
    config:Config.Worker.t ->
    api_config:Config.Api.t Or_error.t Lazy.t ->
    unit ->
    summary
end
