open! Base

(** CLI entry point for PGN ingestion. *)

val run : string -> unit Or_error.t
(** [run path] ingests the PGN located at [path]. Stub for now. *)
