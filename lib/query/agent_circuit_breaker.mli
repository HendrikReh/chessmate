(** Process-wide circuit breaker guarding GPT-5 agent evaluations. *)

open! Base

type status = Disabled | Closed | Half_open | Open
type metrics_hook = open_:bool -> unit
type t

val create : ?metrics_hook:metrics_hook -> unit -> t
(** Create a new circuit-breaker instance. [metrics_hook] defaults to updating
    the Prometheus gauge that tracks breaker state. *)

val configure : t -> threshold:int -> cooloff_seconds:float -> unit
(** Configure the breaker with the supplied threshold and cool-off window. A
    [threshold] <= 0 disables the breaker. Calling [configure] resets the
    internal state. *)

val should_allow : t -> bool
(** Return [true] when the breaker permits an agent evaluation. When the breaker
    is open, this returns [false] and the caller should skip the agent call. *)

val record_success : t -> unit
(** Notify the breaker that the most recent agent attempt succeeded. Resets
    failure counters and closes the breaker if it was half-open. *)

val record_failure : t -> unit
(** Notify the breaker that the most recent agent attempt failed or timed out.
    When failures reach the configured threshold, the breaker opens for the
    configured cool-off period. *)

val current_status : t -> status
(** Current breaker state, taking into account elapsed cool-off time. *)

val status_to_string : status -> string
(** Human-readable representation for logging and JSON responses. *)
