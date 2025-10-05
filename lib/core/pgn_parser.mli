open! Base

(** PGN parsing and normalization utilities. *)

type move = {
  san : string;
  turn : int;
  ply : int;
}

(** Parsed PGN artifact with metadata headers and SAN moves. *)
type t = {
  headers : (string * string) list;
  moves : move list;
}

val parse : string -> t Or_error.t
(** [parse raw_pgn] parses [raw_pgn] text into structured data.
    Stub currently returns an error until the real parser is implemented. *)
