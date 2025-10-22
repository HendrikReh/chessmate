open! Base

type ingest_result = [ `Stored | `Skipped ]
type ingest_outcome = [ `Success | `Failure ]

val record_ingest_game : result:ingest_result -> unit
val record_ingest_run : outcome:ingest_outcome -> duration_s:float -> unit
val set_embedding_pending_jobs : int -> unit
val reset_for_tests : unit -> unit
