open! Base

val create : ?prefix:string -> ?suffix:string -> unit -> string Or_error.t
(** [create ()] returns the path to a newly created temporary file located in
    [Filename.temp_dir_name]. The file is registered for automatic cleanup on
    process exit or shutdown signals. *)

val register : string -> unit Or_error.t
(** Register an existing temporary file for cleanup. *)

val remove : string -> unit
(** Remove (best-effort) a previously registered file and drop it from the
    cleanup set. It is not an error if the file is already missing. *)

val cleanup_now : unit -> unit
(** Force an immediate cleanup of all registered files. Intended for tests. *)
