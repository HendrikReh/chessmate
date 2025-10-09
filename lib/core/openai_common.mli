open! Base

type retry_config = {
  max_attempts : int;
  initial_delay : float;
  multiplier : float;
  jitter : float;
}

val default_retry_config : retry_config
val load_retry_config : unit -> retry_config
val should_retry_status : int -> bool
val should_retry_error_json : Yojson.Safe.t -> bool
val truncate_body : string -> string
val log_retry :
  label:string ->
  attempt:int ->
  max_attempts:int ->
  delay:float ->
  Error.t ->
  unit
