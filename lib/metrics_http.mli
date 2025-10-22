open! Base

type t

val start : port:int -> t Or_error.t
(** Start a Prometheus HTTP exporter on the provided [port]. *)

val start_if_configured : port:int option -> t option Or_error.t
(** Convenience helper returning [Ok None] when no port is supplied. *)

val stop : t -> unit
(** Stop the exporter and release resources. Safe to call multiple times. *)

val stop_opt : t option -> unit
(** [stop_opt] is a no-op when given [None]. *)
