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

val record_request : route:string -> latency_ms:float -> status:int -> unit
val render : unit -> string list
val record_agent_cache_hit : unit -> unit
val record_agent_cache_miss : unit -> unit
val record_agent_evaluation : success:bool -> latency_ms:float -> unit
val set_agent_circuit_state : open_:bool -> unit
val reset_for_tests : unit -> unit
