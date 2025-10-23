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
    type t = {
      requests_per_minute : int;
      bucket_size : int option;
      body_bytes_per_minute : int option;
      body_bucket_size : int option;
    }
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

  let ( let* ) t f = Or_error.bind t ~f

  type agent = {
    api_key : string option;
    endpoint : string;
    model : string option;
    reasoning_effort : Agents_gpt5_client.Effort.t;
    verbosity : Agents_gpt5_client.Verbosity.t option;
    request_timeout_seconds : float;
    cache : Agent_cache.t;
    candidate_multiplier : int;
    candidate_max : int;
    circuit_breaker_threshold : int;
    circuit_breaker_cooloff_seconds : float;
  }

  type t = {
    database_url : string;
    qdrant_url : string;
    port : int;
    agent : agent;
    rate_limit : Rate_limit.t option;
    qdrant_collection : Qdrant.collection option;
    max_request_body_bytes : int option;
  }

  let default_port = 8080
  let default_agent_endpoint = "https://api.openai.com/v1/responses"
  let default_collection_name = "positions"
  let default_vector_size = 1536
  let default_distance = "Cosine"
  let default_agent_timeout_seconds = 15.
  let default_agent_candidate_multiplier = 5
  let default_agent_candidate_max = 25
  let default_agent_circuit_breaker_threshold = 5
  let default_agent_circuit_breaker_cooloff_seconds = 60.
  let default_max_request_body_bytes = 1_048_576

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

  let load_candidate_multiplier () =
    match Helpers.optional "AGENT_CANDIDATE_MULTIPLIER" with
    | None -> Or_error.return default_agent_candidate_multiplier
    | Some raw when String.is_empty raw ->
        Or_error.return default_agent_candidate_multiplier
    | Some raw -> Helpers.parse_positive_int "AGENT_CANDIDATE_MULTIPLIER" raw

  let load_candidate_max () =
    match Helpers.optional "AGENT_CANDIDATE_MAX" with
    | None -> Or_error.return default_agent_candidate_max
    | Some raw when String.is_empty raw ->
        Or_error.return default_agent_candidate_max
    | Some raw -> Helpers.parse_positive_int "AGENT_CANDIDATE_MAX" raw

  let load_circuit_breaker_threshold () =
    match Helpers.optional "AGENT_CIRCUIT_BREAKER_THRESHOLD" with
    | None -> Or_error.return default_agent_circuit_breaker_threshold
    | Some raw when String.is_empty raw ->
        Or_error.return default_agent_circuit_breaker_threshold
    | Some raw -> Helpers.parse_int "AGENT_CIRCUIT_BREAKER_THRESHOLD" raw

  let load_circuit_breaker_cooloff () =
    match Helpers.optional "AGENT_CIRCUIT_BREAKER_COOLOFF_SECONDS" with
    | None -> Or_error.return default_agent_circuit_breaker_cooloff_seconds
    | Some raw when String.is_empty raw ->
        Or_error.return default_agent_circuit_breaker_cooloff_seconds
    | Some raw ->
        Helpers.parse_positive_float "AGENT_CIRCUIT_BREAKER_COOLOFF_SECONDS" raw

  let load_max_request_body_bytes () =
    match Helpers.optional "CHESSMATE_MAX_REQUEST_BODY_BYTES" with
    | None -> Or_error.return (Some default_max_request_body_bytes)
    | Some raw when String.is_empty raw ->
        Or_error.return (Some default_max_request_body_bytes)
    | Some raw -> (
        match Helpers.parse_int "CHESSMATE_MAX_REQUEST_BODY_BYTES" raw with
        | Error err -> Error err
        | Ok value when value < 0 ->
            Helpers.invalid "CHESSMATE_MAX_REQUEST_BODY_BYTES" raw
              "expected a non-negative integer"
        | Ok 0 -> Or_error.return None
        | Ok value -> Or_error.return (Some value))

  let load_agent () =
    let api_key = Helpers.optional "AGENT_API_KEY" in
    let endpoint =
      Option.value
        (Helpers.optional "AGENT_ENDPOINT")
        ~default:default_agent_endpoint
    in
    let model = Helpers.optional "AGENT_MODEL" in
    let* reasoning_effort = load_reasoning_effort () in
    let* verbosity = load_verbosity () in
    let* cache = load_agent_cache () in
    let* request_timeout_seconds = load_agent_timeout () in
    let* candidate_multiplier = load_candidate_multiplier () in
    let* candidate_max = load_candidate_max () in
    let* circuit_breaker_threshold = load_circuit_breaker_threshold () in
    let* circuit_breaker_cooloff_seconds =
      load_circuit_breaker_cooloff ()
    in
    Or_error.return
      {
        api_key;
        endpoint;
        model;
        reasoning_effort;
        verbosity;
        request_timeout_seconds;
        cache;
        candidate_multiplier;
        candidate_max;
        circuit_breaker_threshold;
        circuit_breaker_cooloff_seconds;
      }

  let load_rate_limit () =
    let parse_optional_positive name =
      match Helpers.optional name with
      | None | Some "" -> Or_error.return None
      | Some raw ->
          Helpers.parse_positive_int name raw |> Or_error.map ~f:Option.some
    in
    let parse_body_bucket ~body_bytes_per_minute =
      match Helpers.optional "CHESSMATE_RATE_LIMIT_BODY_BUCKET_SIZE" with
      | None | Some "" -> Or_error.return None
      | Some raw -> (
          match body_bytes_per_minute with
          | None ->
              Helpers.invalid "CHESSMATE_RATE_LIMIT_BODY_BUCKET_SIZE" raw
                "requires CHESSMATE_RATE_LIMIT_BODY_BYTES_PER_MINUTE"
          | Some _ ->
              Helpers.parse_positive_int "CHESSMATE_RATE_LIMIT_BODY_BUCKET_SIZE"
                raw
              |> Or_error.map ~f:Option.some)
    in
    match Helpers.optional "CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE" with
    | None | Some "" -> Or_error.return None
    | Some raw ->
        let* requests_per_minute =
          Helpers.parse_positive_int "CHESSMATE_RATE_LIMIT_REQUESTS_PER_MINUTE" raw
        in
        let* bucket_size =
          parse_optional_positive "CHESSMATE_RATE_LIMIT_BUCKET_SIZE"
        in
        let* body_bytes_per_minute =
          parse_optional_positive "CHESSMATE_RATE_LIMIT_BODY_BYTES_PER_MINUTE"
        in
        let* body_bucket_size = parse_body_bucket ~body_bytes_per_minute in
        Or_error.return
          (Some
             {
               Rate_limit.requests_per_minute;
               bucket_size;
               body_bytes_per_minute;
               body_bucket_size;
             })

  let load_qdrant_collection () =
    let normalise_distance raw =
      match raw with
      | None | Some "" -> default_distance
      | Some value -> String.capitalize (String.strip value)
    in
    let* name =
      match Helpers.optional "QDRANT_COLLECTION_NAME" with
      | None | Some "" -> Or_error.return default_collection_name
      | Some raw -> Or_error.return raw
    in
    let distance = normalise_distance (Helpers.optional "QDRANT_DISTANCE") in
    match Helpers.optional "QDRANT_VECTOR_SIZE" with
    | None ->
        Or_error.return
          (Some Qdrant.{ name; vector_size = default_vector_size; distance })
    | Some raw ->
        let* vector_size = Helpers.parse_positive_int "QDRANT_VECTOR_SIZE" raw in
        Or_error.return (Some Qdrant.{ name; vector_size; distance })

  let load () =
    let* database_url = Helpers.require "DATABASE_URL" in
    let* qdrant_url = Helpers.require "QDRANT_URL" in
    let* port = load_port () in
    let* agent = load_agent () in
    let* rate_limit = load_rate_limit () in
    let* qdrant_collection = load_qdrant_collection () in
    let* max_request_body_bytes = load_max_request_body_bytes () in
    Or_error.return
      {
        database_url;
        qdrant_url;
        port;
        agent;
        rate_limit;
        qdrant_collection;
        max_request_body_bytes;
      }
end

module Worker = struct
  type t = {
    database_url : string;
    openai_api_key : string;
    openai_endpoint : string;
    batch_size : int;
    health_port : int;
    prometheus_port : int option;
  }

  let default_endpoint = "https://api.openai.com/v1/embeddings"
  let default_batch_size = 16
  let default_health_port = 8081
  let prometheus_env = "CHESSMATE_WORKER_PROM_PORT"

  let load_batch_size () =
    match Helpers.optional "CHESSMATE_WORKER_BATCH_SIZE" with
    | None -> Or_error.return default_batch_size
    | Some raw when String.is_empty raw -> Or_error.return default_batch_size
    | Some raw -> Helpers.parse_positive_int "CHESSMATE_WORKER_BATCH_SIZE" raw

  let load_health_port () =
    match Helpers.optional "CHESSMATE_WORKER_HEALTH_PORT" with
    | None -> Or_error.return default_health_port
    | Some raw when String.is_empty raw -> Or_error.return default_health_port
    | Some raw -> Helpers.parse_positive_int "CHESSMATE_WORKER_HEALTH_PORT" raw

  let load_prometheus_port () =
    match Helpers.optional prometheus_env with
    | None -> Or_error.return None
    | Some raw when String.is_empty raw -> Or_error.return None
    | Some raw -> (
        match Helpers.parse_positive_int prometheus_env raw with
        | Error err -> Error err
        | Ok port when port <= 65_535 -> Or_error.return (Some port)
        | Ok _ ->
            Helpers.invalid prometheus_env raw "expected a TCP port (1-65535)")

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
            | Ok batch_size -> (
                match load_health_port () with
                | Error err -> Error err
                | Ok health_port -> (
                    match load_prometheus_port () with
                    | Error err -> Error err
                    | Ok prometheus_port ->
                        Or_error.return
                          {
                            database_url;
                            openai_api_key;
                            openai_endpoint;
                            batch_size;
                            health_port;
                            prometheus_port;
                          }))))
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
