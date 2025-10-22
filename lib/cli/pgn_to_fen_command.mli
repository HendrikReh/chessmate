(** CLI command that converts PGNs into streams of FEN positions. *)

open! Base

val run : input:string -> output:string option -> unit Or_error.t
(** [run ~input ~output] reads the PGN at [input], converts each half-move to a
    FEN string via [Pgn_to_fen], and either prints them (when [output=None]) or
    writes them to [output] (overwriting the file). *)
