open! Base

(** Client wrapper around the OpenAI GPT-5 Responses API with configurable
    effort and verbosity. *)

module Effort : sig
  (** Reasoning effort levels supported by GPT-5. *)
  type t = Minimal | Low | Medium | High

  val to_string : t -> string
  val of_string : string -> t Or_error.t
end

(** Verbosity controls for GPT-5 responses. *)
module Verbosity : sig
  type t = Low | Medium | High

  val to_string : t -> string
  val of_string : string -> t Or_error.t
end

(** Supported message roles. *)
module Role : sig
  type t = System | User | Assistant
end

(** Response formatting options. *)
module Response_format : sig
  type t = Text | Json_schema of Yojson.Safe.t
end

(** Prompt message representation. *)
module Message : sig
  type t = { role : Role.t; content : string }
end

(** Token usage metadata returned by GPT-5. *)
module Usage : sig
  type t = {
    input_tokens : int option;
    output_tokens : int option;
    reasoning_tokens : int option;
  }

  val empty : t
end

(** Parsed GPT-5 response. *)
module Response : sig
  type t = { content : string; usage : Usage.t; raw_json : Yojson.Safe.t }
end

type t
(** GPT-5 client handle. *)

val create :
  api_key:string ->
  ?endpoint:string ->
  ?model:string ->
  ?default_effort:Effort.t ->
  ?default_verbosity:Verbosity.t ->
  unit ->
  t Or_error.t
(** [create ~api_key ?endpoint ?model ?default_effort ?default_verbosity ()]
    instantiates a GPT-5 client. Defaults: endpoint =
    "https://api.openai.com/v1/responses", model = "gpt-5", effort =
    [Effort.Medium]. *)

val create_from_env : unit -> t Or_error.t
(** [create_from_env ()] reads [AGENT_API_KEY], [AGENT_ENDPOINT], [AGENT_MODEL],
    [AGENT_REASONING_EFFORT], and [AGENT_VERBOSITY] to construct a client. Retry
    behaviour can be tuned globally via [OPENAI_RETRY_MAX_ATTEMPTS] and
    [OPENAI_RETRY_BASE_DELAY_MS]. *)

val generate :
  t ->
  ?reasoning_effort:Effort.t ->
  ?verbosity:Verbosity.t ->
  ?max_output_tokens:int ->
  ?response_format:Response_format.t ->
  Message.t list ->
  Response.t Or_error.t
(** Execute a GPT-5 call with the supplied messages. Optional parameters
    override the client's defaults for reasoning effort, verbosity, response
    format, and token limit. Transient failures (HTTP 429/5xx, server errors)
    are retried automatically using exponential backoff obeying
    [OPENAI_RETRY_MAX_ATTEMPTS] and [OPENAI_RETRY_BASE_DELAY_MS] when set. *)
