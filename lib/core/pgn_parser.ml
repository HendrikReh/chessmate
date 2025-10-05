open! Base

type move = {
  san : string;
  turn : int;
  ply : int;
}

type t = {
  headers : (string * string) list;
  moves : move list;
}

let parse (_raw : string) : t Or_error.t =
  Or_error.error_string "PGN parser not implemented yet"
