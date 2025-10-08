open! Base

(** Unique key for caching GPT-5 evaluations. *)
type key = string

val key_of_plan : plan:Query_intent.plan -> summary:Repo_postgres.game_summary -> pgn:string -> key

(** Cached evaluation payload. *)
type entry = Agent_evaluator.evaluation

(** Cache handle supporting in-memory or Redis backends. *)
type t

val create : capacity:int -> t
val create_redis : ?namespace:string -> ?ttl_seconds:int -> string -> t Or_error.t

val find : t -> key -> entry option
val store : t -> key -> entry -> unit
