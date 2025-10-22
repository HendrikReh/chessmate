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
