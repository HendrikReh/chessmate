(** Health checks for external services required by the CLI. *)

open! Base

val ensure_all : unit -> unit Or_error.t
(** Probe Redis, Postgres, Qdrant, and the Chessmate API. A summary is printed
    to stderr; returns [Ok ()] when all required services respond, otherwise an
    error describing the first unavailable dependency. *)
