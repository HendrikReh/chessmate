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

type retry_config = {
  max_attempts : int;
  initial_delay : float;
  multiplier : float;
  jitter : float;
}

val default_retry_config : retry_config
val load_retry_config : unit -> retry_config Or_error.t
val should_retry_status : int -> bool
val should_retry_error_json : Yojson.Safe.t -> bool
val truncate_body : string -> string

val log_retry :
  label:string ->
  attempt:int ->
  max_attempts:int ->
  delay:float ->
  Error.t ->
  unit
