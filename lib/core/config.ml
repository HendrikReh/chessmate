open! Base

module Helpers = struct
  let trimmed_env name =
    Stdlib.Sys.getenv_opt name
    |> Option.map ~f:String.strip
    |> Option.filter ~f:(fun value -> not (String.is_empty value))

  let missing name =
    Or_error.errorf "Configuration error: %s environment variable is required" name

  let invalid name value message =
    Or_error.errorf "Configuration error: %s=%s is invalid (%s)" name value message

  let require name =
    match trimmed_env name with
    | Some value -> Or_error.return value
    | None -> missing name

  let optional name = trimmed_env name

  let parse_int name value =
    match Int.of_string value with
    | exception _ -> invalid name value "expected integer"
    | parsed -> Or_error.return parsed

  let parse_positive_int name value =
    match parse_int name value with
    | Ok parsed when parsed > 0 -> Or_error.return parsed
    | Ok _ -> invalid name value "expected a positive integer"
    | Error err -> Error err
end

module Api = struct
  module Agent_cache = struct
    type t =
      | Redis of {
          url : string;
          namespace : string option;
          ttl_seconds : int option;
        }
      | Memory of {
          capacity : int option;
        }
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
  }

  let default_port = 8080
  let default_agent_endpoint = "https://api.openai.com/v1/responses"

  let load_port () =
    match Helpers.optional "CHESSMATE_API_PORT" with
    | None -> Or_error.return default_port
    | Some raw -> (
        match Helpers.parse_int "CHESSMATE_API_PORT" raw with
        | Ok parsed when parsed > 0 -> Or_error.return parsed
        | Ok _ -> Helpers.invalid "CHESSMATE_API_PORT" raw "expected a positive integer"
        | Error err -> Error err)

  let load_reasoning_effort () =
    match Helpers.optional "AGENT_REASONING_EFFORT" with
    | None -> Or_error.return Agents_gpt5_client.Effort.Medium
    | Some raw -> Agents_gpt5_client.Effort.of_string raw

  let load_verbosity () =
    match Helpers.optional "AGENT_VERBOSITY" with
    | None -> Or_error.return None
    | Some raw ->
        Agents_gpt5_client.Verbosity.of_string raw |> Or_error.map ~f:Option.some

  let load_agent_cache () =
    match Helpers.optional "AGENT_CACHE_REDIS_URL" with
    | Some url ->
        let namespace = Helpers.optional "AGENT_CACHE_REDIS_NAMESPACE" in
        let ttl_seconds =
          match Helpers.optional "AGENT_CACHE_TTL_SECONDS" with
          | None -> Ok None
          | Some raw -> (
              match Helpers.parse_positive_int "AGENT_CACHE_TTL_SECONDS" raw with
              | Ok ttl -> Ok (Some ttl)
              | Error err -> Error err)
        in
        (match ttl_seconds with
        | Ok ttl -> Ok (Agent_cache.Redis { url; namespace; ttl_seconds = ttl })
        | Error err -> Error err)
    | None -> (
        match Helpers.optional "AGENT_CACHE_CAPACITY" with
        | None -> Or_error.return Agent_cache.Disabled
        | Some raw when String.is_empty raw -> Or_error.return Agent_cache.Disabled
        | Some raw -> (
            match Helpers.parse_positive_int "AGENT_CACHE_CAPACITY" raw with
            | Ok capacity -> Or_error.return (Agent_cache.Memory { capacity = Some capacity })
            | Error err -> Error err ))

  let load_agent () =
    let api_key = Helpers.optional "AGENT_API_KEY" in
    let endpoint = Option.value (Helpers.optional "AGENT_ENDPOINT") ~default:default_agent_endpoint in
    let model = Helpers.optional "AGENT_MODEL" in
    match load_reasoning_effort () with
    | Error err -> Error err
    | Ok reasoning_effort ->
        (match load_verbosity () with
        | Error err -> Error err
        | Ok verbosity ->
            (match load_agent_cache () with
            | Error err -> Error err
            | Ok cache -> Or_error.return { api_key; endpoint; model; reasoning_effort; verbosity; cache }))

  let load () =
    match Helpers.require "DATABASE_URL" with
    | Error err -> Error err
    | Ok database_url -> (
        match Helpers.require "QDRANT_URL" with
        | Error err -> Error err
        | Ok qdrant_url -> (
            match load_port () with
            | Error err -> Error err
            | Ok port -> (
                match load_agent () with
                | Error err -> Error err
                | Ok agent -> Or_error.return { database_url; qdrant_url; port; agent })) )
end

module Worker = struct
  type t = {
    database_url : string;
    openai_api_key : string;
    openai_endpoint : string;
  }

  let default_endpoint = "https://api.openai.com/v1/embeddings"

  let load () =
    match Helpers.require "DATABASE_URL" with
    | Error err -> Error err
    | Ok database_url ->
        (match Helpers.require "OPENAI_API_KEY" with
        | Error err -> Error err
        | Ok openai_api_key ->
            let openai_endpoint =
              Option.value (Helpers.optional "OPENAI_EMBEDDING_ENDPOINT") ~default:default_endpoint
            in
            Or_error.return { database_url; openai_api_key; openai_endpoint })
end

module Cli = struct
  let database_url () = Helpers.require "DATABASE_URL"

  let api_base_url () =
    Option.value (Helpers.optional "CHESSMATE_API_URL") ~default:"http://localhost:8080"

  let pending_guard_limit ~default =
    match Helpers.optional "CHESSMATE_MAX_PENDING_EMBEDDINGS" with
    | None -> Or_error.return (Some default)
    | Some raw when String.is_empty raw -> Or_error.return (Some default)
    | Some raw -> (
        match Helpers.parse_int "CHESSMATE_MAX_PENDING_EMBEDDINGS" raw with
        | Error err -> Error err
        | Ok value when value <= 0 -> Or_error.return None
        | Ok value -> Or_error.return (Some value))
end
