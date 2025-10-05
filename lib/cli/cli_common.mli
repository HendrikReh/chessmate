open! Base

(** Shared helpers for command-line entry points. *)

val with_db_url : (string -> 'a Or_error.t) -> 'a Or_error.t
(** Fetch [DATABASE_URL] from the environment and apply the provided function. *)
