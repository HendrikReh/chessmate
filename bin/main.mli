(** Entry point for the [`chessmate`] CLI. *)

val run : ?argv:string array -> unit -> unit
(** Execute the CLI using [argv] (defaults to [Sys.argv]) and dispatch the
    selected subcommand. *)
