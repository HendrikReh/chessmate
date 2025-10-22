open! Base

module Metrics : sig
  type t = {
    processed : int;
    failed : int;
    jobs_per_min : float;
    chars_per_sec : float;
    queue_depth : int;
  }
end

val start :
  port:int ->
  summary:(unit -> Health.summary) ->
  metrics:(unit -> (Metrics.t, string) Result.t) ->
  (unit -> unit) Or_error.t
(** [start ~port ~summary ~metrics] launches an HTTP server exposing `/health`
    (JSON) and `/metrics` (Prometheus style). The returned function stops the
    server. *)
