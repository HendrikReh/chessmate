(** Implements the `chessmate ingest` CLI command. *)

open! Base

(** Ingest a PGN file into the configured Postgres instance. *)
val run : string -> unit Or_error.t
(** [run path] reads the PGN at [path], parses it, and persists metadata/
    positions using [DATABASE_URL]. Aborts early if the embedding queue exceeds
    [CHESSMATE_MAX_PENDING_EMBEDDINGS]. Prints a summary on success. *)
