(** Implements the `chessmate query` CLI command. *)

open! Base

(** CLI entry point for querying the `/query` HTTP API (backed by the prototype
    planning pipeline). *)

val run :
  ?as_json:bool -> ?limit:int -> ?offset:int -> string -> unit Or_error.t
(** [run ?as_json question] posts [question] to the query API resolved by
    [CHESSMATE_API_URL]. When [as_json] is [true], the raw JSON body returned by
    the service is printed; otherwise a human-readable summary is rendered. *)
