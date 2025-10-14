open! Base

module Helpers = struct
  let trimmed_env ?(strip = true) name =
    Stdlib.Sys.getenv_opt name
    |> Option.map ~f:(fun value -> if strip then String.strip value else value)
    |> Option.filter ~f:(fun value -> not (String.is_empty value))

  let missing name =
    Or_error.errorf "Configuration error: %s environment variable is required"
      name

  let invalid name value message =
    Or_error.errorf "Configuration error: %s=%s is invalid (%s)" name value
      message

  let require ?(strip = true) name =
    match trimmed_env ~strip name with
    | Some value -> Or_error.return value
    | None -> missing name

  let optional ?(strip = true) name = trimmed_env ~strip name

  let parse_int name value =
    match Int.of_string value with
    | exception _ -> invalid name value "expected integer"
    | parsed -> Or_error.return parsed

  let parse_positive_int name value =
    match parse_int name value with
    | Ok parsed when parsed > 0 -> Or_error.return parsed
    | Ok _ -> invalid name value "expected a positive integer"
    | Error err -> Error err

  let parse_positive_float name value =
    match Float.of_string value with
    | exception _ -> invalid name value "expected a floating value"
    | parsed when Float.(parsed > 0.) -> Or_error.return parsed
    | _ -> invalid name value "expected a positive floating value"
end

module Api = struct
  module Rate_limit = struct
    type t = { requests_per_minute : int; bucket_size : int option }
  end

  module Qdrant = struct
    type collection = { name : string; vector_size : int; distance : string }
  end

  module Agent_cache = struct
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
    request_timeout_seconds : float;
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

  let default_port = 8080
  let default_agent_endpoint = "https://api.openai.com/v1/responses"
  let default_collection_name = "positions"
  let default_vector_size = 1536
  let default_distance = "Cosine"
  let default_agent_timeout_seconds = 15.

  let load_port () =
    match Helpers.optional "CHESSMATE_API_PORT" with
    | None -> Or_error.return default_port
    | Some raw -> Helpers.parse_positive_int "CHESSMATE_API_PORT" raw

  let load_reasoning_effort () =
    match Helpers.optional "AGENT_REASONING_EFFORT" with
    | None -> Or_error.return Agents_gpt5_client.Effort.Medium
    | Some raw -> Agents_gpt5_client.Effort.of_string raw

  let load_verbosity () =
    match Helpers.optional "AGENT_VERBOSITY" with
    | None -> Or_error.return None
    | Some raw ->
        Agents_gpt5_client.Verbosity.of_string raw
        |> Or_error.map ~f:Option.some

  let load_agent_cache () =
    match Helpers.optional "AGENT_CACHE_REDIS_URL" with
    | Some url -> (
        let namespace = Helpers.optional "AGENT_CACHE_REDIS_NAMESPACE" in
        let ttl_seconds =
          match Helpers.optional "AGENT_CACHE_TTL_SECONDS" with
          | None -> Ok None
          | Some raw -> (
              match
                Helpers.parse_positive_int "AGENT_CACHE_TTL_SECONDS" raw
              with
              | Ok ttl -> Ok (Some ttl)
              | Error err -> Error err)
        in
        match ttl_seconds with
        | Ok ttl -> Ok (Agent_cache.Redis { url; namespace; ttl_seconds = ttl })
        | Error err -> Error err)
    | None -> (
        match Helpers.optional "AGENT_CACHE_CAPACITY" with
        | None -> Or_error.return Agent_cache.Disabled
        | Some raw when String.is_empty raw ->
            Or_error.return Agent_cache.Disabled
        | Some raw -> (
            match Helpers.parse_positive_int "AGENT_CACHE_CAPACITY" raw with
            | Ok capacity ->
                Or_error.return
                  (Agent_cache.Memory { capacity = Some capacity })
            | Error err -> Error err))

  let load_agent_timeout () =
    match Helpers.optional "AGENT_REQUEST_TIMEOUT_SECONDS" with
    | None -> Or_error.return default_agent_timeout_seconds
    | Some raw when String.is_empty raw ->
        Or_error.return default_agent_timeout_seconds
    | Some raw ->
        Helpers.parse_positive_float "AGENT_REQUEST_TIMEOUT_SECONDS" raw

  let load_agent () =
    let api_key = Helpers.optional "AGENT_API_KEY" in
    let endpoint =
      Option.value
        (Helpers.optional "AGENT_ENDPOINT")
        ~default:default_agent_endpoint
    in
    let model = Helpers.optional "AGENT_MODEL" in
    match load_reasoning_effort () with
    | Error err -> Error err
    | Ok reasoning_effort -> (
        match load_verbosity () with
        | Error err -> Error err
        | Ok verbosity -> (
            match load_agent_cache () with
            | Error err -> Error err
            | Ok cache -> (
                match load_agent_timeout () with
                | Error err -> Error err
                | Ok request_timeout_seconds ->
                    Or_error.return
                      {
                        api_key;
                        endpoint;
                        model;
                        reasoning_effort;
                        verbosity;
                        request_timeout_seconds;
                        cache;
                      })))

  let load_rate_limit () =
    match Helpers.optional "CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE" with
    | None -> Or_error.return None
    | Some raw when String.is_empty raw -> Or_error.return None
    | Some raw -> (
        match
          Helpers.parse_positive_int "CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE"
            raw
        with
        | Error err -> Error err
        | Ok requests_per_minute -> (
            let bucket_size =
              match Helpers.optional "CHESSMATE_RATE_LIMIT_BUCKET_SIZE" with
              | None -> Ok None
              | Some raw_bucket when String.is_empty raw_bucket -> Ok None
              | Some raw_bucket ->
                  Helpers.parse_positive_int "CHESSMATE_RATE_LIMIT_BUCKET_SIZE"
                    raw_bucket
                  |> Or_error.map ~f:Option.some
            in
            match bucket_size with
            | Error err -> Error err
            | Ok bucket_size ->
                Ok (Some { Rate_limit.requests_per_minute; bucket_size })))

  let load_qdrant_collection () =
    let name_result =
      match Helpers.optional "QDRANT_COLLECTION_NAME" with
      | None -> Ok default_collection_name
      | Some raw when String.is_empty raw -> Ok default_collection_name
      | Some raw -> Ok raw
    in
    match name_result with
    | Error err -> Error err
    | Ok name -> (
        match Helpers.optional "QDRANT_VECTOR_SIZE" with
        | Some raw -> (
            match Helpers.parse_positive_int "QDRANT_VECTOR_SIZE" raw with
            | Error err -> Error err
            | Ok vector_size ->
                let distance =
                  match Helpers.optional "QDRANT_DISTANCE" with
                  | None -> default_distance
                  | Some raw when String.is_empty raw -> default_distance
                  | Some raw -> String.capitalize (String.strip raw)
                in
                Ok (Some Qdrant.{ name; vector_size; distance }))
        | None ->
            let distance =
              match Helpers.optional "QDRANT_DISTANCE" with
              | None -> default_distance
              | Some raw when String.is_empty raw -> default_distance
              | Some raw -> String.capitalize (String.strip raw)
            in
            Ok
              (Some Qdrant.{ name; vector_size = default_vector_size; distance })
        )

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
                | Ok agent -> (
                    match load_rate_limit () with
                    | Error err -> Error err
                    | Ok rate_limit -> (
                        match load_qdrant_collection () with
                        | Error err -> Error err
                        | Ok qdrant_collection ->
                            Or_error.return
                              {
                                database_url;
                                qdrant_url;
                                port;
                                agent;
                                rate_limit;
                                qdrant_collection;
                              })))))
end

module Worker = struct
  type t = {
    database_url : string;
    openai_api_key : string;
    openai_endpoint : string;
    batch_size : int;
  }

  let default_endpoint = "https://api.openai.com/v1/embeddings"
  let default_batch_size = 16

  let load_batch_size () =
    match Helpers.optional "CHESSMATE_WORKER_BATCH_SIZE" with
    | None -> Or_error.return default_batch_size
    | Some raw when String.is_empty raw -> Or_error.return default_batch_size
    | Some raw -> Helpers.parse_positive_int "CHESSMATE_WORKER_BATCH_SIZE" raw

  let load () =
    match Helpers.require "DATABASE_URL" with
    | Error err -> Error err
    | Ok database_url -> (
        match Helpers.require "OPENAI_API_KEY" with
        | Error err -> Error err
        | Ok openai_api_key -> (
            let openai_endpoint =
              Option.value
                (Helpers.optional "OPENAI_EMBEDDING_ENDPOINT")
                ~default:default_endpoint
            in
            match load_batch_size () with
            | Error err -> Error err
            | Ok batch_size ->
                Or_error.return
                  { database_url; openai_api_key; openai_endpoint; batch_size })
        )
end

module Cli = struct
  let database_url () = Helpers.require "DATABASE_URL"

  let api_base_url () =
    Option.value
      (Helpers.optional "CHESSMATE_API_URL")
      ~default:"http://localhost:8080"

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
