(** CLI command that validates TWIC PGN archives before ingestion. *)

open! Base

val run : string -> unit Or_error.t
(** Inspect a TWIC (or similar multi-game) PGN and report potential issues. *)
