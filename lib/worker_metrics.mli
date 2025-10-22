open! Base

val record_job_completion : failed:bool -> fen_chars:float -> unit
val observe_throughput : jobs_per_min:float -> chars_per_sec:float -> unit
val set_queue_depth : int -> unit
val reset_for_tests : unit -> unit
