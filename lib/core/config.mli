open! Base

module Helpers : sig
  val trimmed_env : ?strip:bool -> string -> string option
  val missing : string -> 'a Or_error.t
  val invalid : string -> string -> string -> 'a Or_error.t
  val require : ?strip:bool -> string -> string Or_error.t
  val optional : ?strip:bool -> string -> string option
  val parse_int : string -> string -> int Or_error.t
  val parse_positive_int : string -> string -> int Or_error.t
  val parse_positive_float : string -> string -> float Or_error.t
end

module Api : sig
  module Rate_limit : sig
    type t = { requests_per_minute : int; bucket_size : int option }
  end

  module Qdrant : sig
    type collection = { name : string; vector_size : int; distance : string }
  end

  module Agent_cache : sig
    type t =
      | Redis of {
          url : string;
          namespace : string option;
          ttl_seconds : int option;
        }
      | Memory of { capacity : int option }
      | Disabled
  end

  type agent = {
    api_key : string option;
    endpoint : string;
    model : string option;
    reasoning_effort : Agents_gpt5_client.Effort.t;
    verbosity : Agents_gpt5_client.Verbosity.t option;
    cache : Agent_cache.t;
  }

  type t = {
    database_url : string;
    qdrant_url : string;
    port : int;
    agent : agent;
    rate_limit : Rate_limit.t option;
    qdrant_collection : Qdrant.collection option;
  }

  val load : unit -> t Or_error.t
end

module Worker : sig
  type t = {
    database_url : string;
    openai_api_key : string;
    openai_endpoint : string;
  }

  val load : unit -> t Or_error.t
end

module Cli : sig
  val database_url : unit -> string Or_error.t
  val api_base_url : unit -> string
  val pending_guard_limit : default:int -> int option Or_error.t
end
