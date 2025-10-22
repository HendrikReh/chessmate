(** Legacy CLI converting PGN move lists into sequential FEN snapshots. *)

val run : ?argv:string array -> unit -> unit
(** Execute the converter using [argv] (defaults to [Sys.argv]). Exits the
    process with an error message when arguments are invalid or conversion
    fails. *)
