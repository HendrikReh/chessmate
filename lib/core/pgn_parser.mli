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

val ply_count : t -> int
val white_name : t -> string option
val black_name : t -> string option
val white_rating : t -> int option
val black_rating : t -> int option
val event : t -> string option
val site : t -> string option
val round : t -> string option
val result : t -> string option
val event_date : t -> string option
val white_move : t -> int -> move option
val black_move : t -> int -> move option
val tag_value : t -> string -> string option
