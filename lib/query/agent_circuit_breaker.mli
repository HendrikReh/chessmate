(** Process-wide circuit breaker guarding GPT-5 agent evaluations. *)

open! Base

type status = Disabled | Closed | Half_open | Open

val configure : threshold:int -> cooloff_seconds:float -> unit
(** Configure the breaker with the supplied threshold and cool-off window. A
    [threshold] <= 0 disables the breaker. Calling [configure] resets the
    internal state. *)

val should_allow : unit -> bool
(** Return [true] when the breaker permits an agent evaluation. When the breaker
    is open, this returns [false] and the caller should skip the agent call. *)

val record_success : unit -> unit
(** Notify the breaker that the most recent agent attempt succeeded. Resets
    failure counters and closes the breaker if it was half-open. *)

val record_failure : unit -> unit
(** Notify the breaker that the most recent agent attempt failed or timed out.
    When failures reach the configured threshold, the breaker opens for the
    configured cool-off period. *)

val current_status : unit -> status
(** Current breaker state, taking into account elapsed cool-off time. *)

val status_to_string : status -> string
(** Human-readable representation for logging and JSON responses. *)
