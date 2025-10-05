open! Base

(** FEN (Forsyth-Edwards Notation) helpers. *)

type t = string

val normalize : t -> t Or_error.t
(** Normalize and validate a FEN string. Currently a stub that validates non-empty input. *)

val hash : t -> string
(** Stable hash for storing deduplicated positions. *)
