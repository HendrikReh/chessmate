open! Base

(* Placeholder implementation for PostgreSQL interactions.
   The actual persistence layer will be provided once a driver is wired in. *)

type t = string

let create conninfo =
  if String.is_empty conninfo then
    Or_error.error_string "Postgres connection string cannot be empty"
  else
    Or_error.return conninfo

let insert_game (_repo : t) ~metadata:_ ~pgn:_ ~moves:_ =
  Or_error.error_string "Postgres persistence is not implemented yet"
