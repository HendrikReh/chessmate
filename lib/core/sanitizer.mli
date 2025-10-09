(** Utilities for scrubbing secrets from error messages. *)

open! Base

val sanitize_string : string -> string
(** Redacts known secret patterns (API keys, connection strings) from the input string. *)

val sanitize_error : Error.t -> string
(** Convert an [Error.t] to a sanitized string. *)

