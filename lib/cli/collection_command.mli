open! Base

val snapshot :
  ?log_path:string ->
  ?note:string ->
  ?snapshot_name:string ->
  unit ->
  unit Or_error.t
(** Perform a Qdrant collection snapshot, optionally annotating the metadata log
    with an operator note.
    @param log_path
      Override the log destination (defaults to
      `snapshots/qdrant_snapshots.jsonl` or the [CHESSMATE_SNAPSHOT_LOG]
      environment variable).
    @param note Free-form annotation stored alongside the snapshot metadata.
    @param snapshot_name
      Optional label passed to Qdrant; the server generates a timestamped name
      when omitted. *)

val restore :
  ?log_path:string ->
  ?snapshot_name:string ->
  ?location:string ->
  unit ->
  unit Or_error.t
(** Restore the collection from either an explicit filesystem [location] or the
    latest entry in the metadata log matching [snapshot_name]. One of
    [snapshot_name] or [location] must be supplied. *)

val list : ?log_path:string -> unit -> unit Or_error.t
(** Print snapshots reported by Qdrant as well as locally recorded metadata.
    @param log_path Alternate metadata log location to read from. *)
