open! Base

type t

type decision =
  | Allowed of { remaining : float }
  | Limited of { retry_after : float; remaining : float }

val create :
  ?idle_timeout:float ->
  ?prune_interval:float ->
  ?time_source:(unit -> float) ->
  tokens_per_minute:int ->
  bucket_size:int ->
  unit ->
  t
(** [create] builds a token-bucket rate limiter. [tokens_per_minute] and
    [bucket_size] must be positive. [idle_timeout] (seconds) controls how long
    to keep per-IP buckets idle before pruning, [prune_interval] (seconds)
    throttles pruning work. The [time_source] parameter is primarily intended
    for tests. Callers should pass [()] once the labelled arguments are
    provided. *)

val check : t -> remote_addr:string -> decision
(** Consume a token for [remote_addr]. Returns [Allowed] when under the limit,
    otherwise [Limited] with the suggested retry-after interval in seconds. *)

val metrics : t -> string list
(** Render Prometheus-style metrics lines describing total and per-IP throttles.
*)

val active_bucket_count : t -> int
(** Return the number of active buckets after pruning stale entries. *)
