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

type 'a attempt = Resolved of 'a Or_error.t | Retry of Error.t

val with_backoff :
  ?sleep:(float -> unit) ->
  ?random:(unit -> float) ->
  ?on_retry:(attempt:int -> delay:float -> Error.t -> unit) ->
  max_attempts:int ->
  initial_delay:float ->
  multiplier:float ->
  ?max_delay:float ->
  jitter:float ->
  f:(attempt:int -> 'a attempt) ->
  unit ->
  'a Or_error.t
(** [with_backoff ~max_attempts ~initial_delay ~multiplier ~jitter ~f] executes
    [f] until it returns a resolved result or the retry budget is exhausted.

    When [f] yields [Retry error], the helper sleeps for the current delay
    (optionally jittered) before trying again, multiplying the delay by
    [multiplier] after each attempt and capping it at [max_delay].

    Raises [Invalid_argument] if [max_attempts < 1]. *)
