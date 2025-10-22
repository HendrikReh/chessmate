(** Shared CLI helpers for environment setup, logging, and error reporting. *)

open! Base

val with_db_url : (string -> 'a Or_error.t) -> 'a Or_error.t
(** Fetch [DATABASE_URL] via {!Config.Cli.database_url} and apply the provided
    function. *)

val api_base_url : unit -> string
(** Resolve the query API base URL via {!Config.Cli.api_base_url}. *)

val positive_int_from_env : name:string -> default:int -> int Or_error.t
(** Parse [name] from the environment as a positive integer. Returns [default]
    when unset; yields a configuration error when the variable is present but
    malformed or non-positive. *)

val positive_float_from_env : name:string -> default:float -> float Or_error.t
(** Parse [name] from the environment as a positive floating-point value.
    Returns [default] when unset; errors on malformed or non-positive input. *)

val prometheus_port_from_env : unit -> int option Or_error.t
(** Read [CHESSMATE_PROM_PORT] when present and validate it as a TCP port. *)
