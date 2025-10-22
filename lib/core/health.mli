open! Base

type probe_result =
  [ `Ok of string option | `Error of string | `Skipped of string ]

type check_state =
  | Healthy of string option
  | Unhealthy of string
  | Skipped of string

type check = {
  name : string;
  required : bool;
  latency_ms : float option;
  state : check_state;
}

type summary_status = [ `Ok | `Degraded | `Error ]
type summary = { status : summary_status; checks : check list }

val summary_to_yojson : summary -> Yojson.Safe.t
val http_status_of : summary_status -> Cohttp.Code.status

module Test_hooks : sig
  type overrides = {
    postgres : (unit -> probe_result) option;
    qdrant : (unit -> probe_result) option;
    redis : (unit -> probe_result) option;
    openai : (unit -> probe_result) option;
    embeddings : (unit -> probe_result) option;
  }

  val empty : overrides
  val with_overrides : overrides -> f:(unit -> 'a) -> 'a
end

module Api : sig
  val summary :
    ?postgres:Repo_postgres.t Or_error.t Lazy.t ->
    config:Config.Api.t ->
    unit ->
    summary
end

module Worker : sig
  val summary :
    ?postgres:Repo_postgres.t Or_error.t Lazy.t ->
    config:Config.Worker.t ->
    api_config:Config.Api.t Or_error.t Lazy.t ->
    unit ->
    summary
end
