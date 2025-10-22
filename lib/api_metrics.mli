open! Base

val record_request : route:string -> latency_ms:float -> status:int -> unit
val record_agent_cache_hit : unit -> unit
val record_agent_cache_miss : unit -> unit
val record_agent_evaluation : success:bool -> latency_ms:float -> unit
val set_agent_circuit_state : open_:bool -> unit
val record_query_embedding : source:string -> latency_ms:float -> unit

val set_db_pool_stats :
  capacity:int ->
  in_use:int ->
  available:int ->
  waiting:int ->
  wait_ratio:float ->
  unit

val registry : unit -> Metrics.Registry.t
val collect : unit -> string Lwt.t
val reset_for_tests : unit -> unit
