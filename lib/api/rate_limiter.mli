open! Base

type t

type decision =
  | Allowed of { remaining : float }
  | Limited of { retry_after : float; remaining : float }

val create : tokens_per_minute:int -> bucket_size:int -> t
(** [create ~tokens_per_minute ~bucket_size] builds a token-bucket rate limiter.
    [tokens_per_minute] and [bucket_size] must be positive. *)

val check : t -> remote_addr:string -> decision
(** Consume a token for [remote_addr]. Returns [Allowed] when under the limit,
    otherwise [Limited] with the suggested retry-after interval in seconds. *)

val metrics : t -> string list
(** Render Prometheus-style metrics lines describing total and per-IP throttles.
*)
