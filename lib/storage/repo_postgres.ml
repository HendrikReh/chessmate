open! Base

type t = string

let create conninfo =
  if String.is_empty conninfo then
    Or_error.error_string "Postgres connection string cannot be empty"
  else
    Ok conninfo

let insert_game (_repo : t) (_metadata : Game_metadata.t) (_raw_pgn : string) =
  Or_error.error_string "Postgres insert_game not implemented yet"
