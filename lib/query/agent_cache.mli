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

(** Caches agent evaluation results using in-memory or Redis backends. *)

open! Base

type key = string
(** Unique key for caching GPT-5 evaluations. *)

val key_of_plan :
  plan:Query_intent.plan ->
  summary:Repo_postgres.game_summary ->
  pgn:string ->
  key
(** Derive a deterministic cache key combining plan metadata, game summary and
    PGN.*)

type entry = Agent_evaluator.evaluation
(** Cached evaluation payload. *)

type t
(** Abstract cache handle; implementation may be in-memory or Redis-backed. *)

val create : capacity:int -> t
(** Create an in-memory cache with an LRU eviction policy and [capacity]. *)

val create_redis :
  ?namespace:string -> ?ttl_seconds:int -> string -> t Or_error.t
(** Connect to Redis using the given URL; optional namespace and TTL configure
    key layout/expiry. *)

val find : t -> key -> entry option
(** Lookup an evaluation in the cache. *)

val store : t -> key -> entry -> unit
(** Insert or update an evaluation. *)

val ping : t -> unit Or_error.t
(** Check backend availability; returns an error if Redis connectivity fails. *)
