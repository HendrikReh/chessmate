(** Opium HTTP service exposing query endpoints and operational routes. *)

open! Base

val routes : Opium.App.t
(** Complete Opium application with rate limiting, health, metrics, and query
    routes. *)

val run_with_shutdown : Opium.App.t -> unit
(** Run the application while handling termination signals for graceful
    shutdown. *)

val run : unit -> unit
(** Start the Chessmate API service using configuration derived from the
    environment. *)
