open! Base

val record_request : route:string -> latency_ms:float -> status:int -> unit
val render : unit -> string list
val record_agent_cache_hit : unit -> unit
val record_agent_cache_miss : unit -> unit
val record_agent_evaluation : success:bool -> latency_ms:float -> unit
val set_agent_circuit_state : open_:bool -> unit
val reset_for_tests : unit -> unit
