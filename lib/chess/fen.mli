(** Utilities for parsing, validating, and manipulating FEN strings. *)

open! Base

type t = string

val normalize : t -> t Or_error.t
(** Normalize and validate a FEN string.

    Ensures that the FEN string contains exactly six space-separated fields,
    validates the board layout, and enforces chess rules such as one king per
    side, pawns not appearing on the first or eighth rank, legal castling
    availability, consistent en passant squares, and well-formed move counters.
    On success the returned string is trimmed and normalized to use single
    spaces between fields. *)

val hash : t -> string
(** Stable hash for storing deduplicated positions. *)
