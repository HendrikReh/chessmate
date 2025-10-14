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

let sanitize = Sanitizer.sanitize_string

let run_probe ~name ~required f =
  let started = Unix.gettimeofday () in
  let state =
    try
      match f () with
      | `Ok detail -> Healthy (Option.map detail ~f:sanitize)
      | `Error err -> Unhealthy (sanitize err)
      | `Skipped reason -> Skipped (sanitize reason)
    with exn -> Unhealthy (sanitize (Exn.to_string exn))
  in
  let latency_ms = (Unix.gettimeofday () -. started) *. 1000.0 in
  { name; required; latency_ms = Some latency_ms; state }

let summary_status checks =
  if
    List.exists checks ~f:(function
      | { required = true; state = Unhealthy _; _ } -> true
      | _ -> false)
  then `Error
  else if
    List.exists checks ~f:(function
      | { state = Unhealthy _; _ } -> true
      | _ -> false)
  then `Degraded
  else `Ok

let check_state_to_string = function
  | Healthy _ -> "ok"
  | Unhealthy _ -> "error"
  | Skipped _ -> "skipped"

let detail_of_state = function
  | Healthy detail -> Option.map detail ~f:(fun d -> `String d)
  | Unhealthy err -> Some (`String err)
  | Skipped reason -> Some (`String reason)

let float_to_json value = `Float value

let check_to_yojson (check : check) =
  let fields =
    [
      ("name", `String check.name);
      ("status", `String (check_state_to_string check.state));
      ("required", `Bool check.required);
      ( "latency_ms",
        match check.latency_ms with
        | None -> `Null
        | Some latency -> float_to_json latency );
      ( "detail",
        match detail_of_state check.state with
        | Some value -> value
        | None -> `Null );
    ]
  in
  `Assoc fields

let summary_to_yojson (summary : summary) =
  let status_string =
    match summary.status with
    | `Ok -> "ok"
    | `Degraded -> "degraded"
    | `Error -> "error"
  in
  `Assoc
    [
      ("status", `String status_string);
      ("checks", `List (List.map summary.checks ~f:check_to_yojson));
    ]

let http_status_of = function
  | `Ok -> `OK
  | `Degraded | `Error -> `Service_unavailable

module Test_hooks = struct
  type overrides = {
    postgres : (unit -> probe_result) option;
    qdrant : (unit -> probe_result) option;
    redis : (unit -> probe_result) option;
    openai : (unit -> probe_result) option;
    embeddings : (unit -> probe_result) option;
  }

  let empty =
    {
      postgres = None;
      qdrant = None;
      redis = None;
      openai = None;
      embeddings = None;
    }

  let overrides_ref = ref empty

  let with_overrides overrides ~f =
    let previous = !overrides_ref in
    overrides_ref := overrides;
    Exn.protect ~f ~finally:(fun () -> overrides_ref := previous)

  let current () = !overrides_ref
end

let current_overrides () = Test_hooks.current ()

let run_dependency ~name ~required override actual =
  run_probe ~name ~required (fun () ->
      match override with Some f -> f () | None -> actual ())

let normalize_base url = String.rstrip (String.strip url) ~drop:(Char.equal '/')

let http_get_with_timeout ~timeout url =
  let open Lwt.Syntax in
  let request =
    Lwt.catch
      (fun () ->
        let uri = Uri.of_string url in
        let* response, body = Cohttp_lwt_unix.Client.get uri in
        let status =
          Cohttp.Response.status response |> Cohttp.Code.code_of_status
        in
        let* body_text = Cohttp_lwt.Body.to_string body in
        Lwt.return (Ok (status, body_text)))
      (fun exn -> Lwt.return (Error (Exn.to_string exn)))
  in
  let timeout_task =
    let* () = Lwt_unix.sleep timeout in
    Lwt.return (Error (Printf.sprintf "request timed out after %.1fs" timeout))
  in
  try Lwt_main.run (Lwt.pick [ request; timeout_task ])
  with exn -> Error (Exn.to_string exn)

let probe_postgres ?existing_repo database_url =
  let connect () =
    match existing_repo with
    | Some repo -> Lazy.force repo
    | None -> Repo_postgres.create database_url
  in
  match connect () with
  | Error err -> `Error (Error.to_string_hum err)
  | Ok repo -> (
      match Repo_postgres.pending_embedding_job_count repo with
      | Error err -> `Error (Error.to_string_hum err)
      | Ok pending ->
          let stats = Repo_postgres.pool_stats repo in
          let detail =
            Printf.sprintf "pending_jobs=%d in_use=%d waiting=%d capacity=%d"
              pending stats.in_use stats.waiting stats.capacity
          in
          `Ok (Some detail))

let probe_qdrant qdrant_url =
  let base = normalize_base qdrant_url in
  let endpoints = [ "/healthz"; "/health" ] in
  let timeout = 3.0 in
  let rec attempt last_error = function
    | [] ->
        let reason = Option.value last_error ~default:"no reachable endpoint" in
        `Error reason
    | path :: rest -> (
        let url = base ^ path in
        match http_get_with_timeout ~timeout url with
        | Ok (200, _) -> `Ok (Some (Printf.sprintf "200 %s" path))
        | Ok (status, body) ->
            let snippet = String.prefix (sanitize body) 120 in
            let message =
              Printf.sprintf "%s returned %d %s" path status snippet
            in
            attempt (Some message) rest
        | Error err -> attempt (Some (sanitize err)) rest)
  in
  attempt None endpoints

let probe_redis cache_config =
  match cache_config with
  | Config.Api.Agent_cache.Disabled -> `Skipped "agent cache disabled"
  | Config.Api.Agent_cache.Memory _ -> `Skipped "in-memory cache"
  | Config.Api.Agent_cache.Redis { url; namespace; ttl_seconds } -> (
      match Agent_cache.create_redis ?namespace ?ttl_seconds url with
      | Error err -> `Error (Error.to_string_hum err)
      | Ok cache -> (
          match Agent_cache.ping cache with
          | Ok () -> `Ok None
          | Error err -> `Error (Error.to_string_hum err)))

let probe_openai agent_config =
  match agent_config.Config.Api.api_key with
  | None -> `Skipped "agent disabled"
  | Some api_key -> (
      match
        Agents_gpt5_client.create ~api_key
          ~endpoint:agent_config.Config.Api.endpoint
          ?model:agent_config.Config.Api.model
          ~default_effort:agent_config.Config.Api.reasoning_effort
          ?default_verbosity:agent_config.Config.Api.verbosity ()
      with
      | Ok _ ->
          let detail =
            Option.value_map agent_config.Config.Api.model
              ~default:"model=default" ~f:(fun model -> "model=" ^ model)
          in
          `Ok (Some detail)
      | Error err -> `Error (Error.to_string_hum err))

let probe_embeddings ~api_key ~endpoint =
  if String.is_empty (String.strip api_key) then `Error "OPENAI_API_KEY missing"
  else if String.is_empty (String.strip endpoint) then
    `Error "OPENAI_ENDPOINT missing"
  else
    match Embedding_client.create ~api_key ~endpoint with
    | Ok _ -> `Ok (Some (Printf.sprintf "endpoint=%s" endpoint))
    | Error err -> `Error (Error.to_string_hum err)

module Api = struct
  let summary ?postgres ~config () =
    let overrides = current_overrides () in
    let postgres_check =
      run_dependency ~name:"postgres" ~required:true overrides.postgres
        (fun () ->
          probe_postgres ?existing_repo:postgres config.Config.Api.database_url)
    in
    let qdrant_check =
      run_dependency ~name:"qdrant" ~required:true overrides.qdrant (fun () ->
          probe_qdrant config.Config.Api.qdrant_url)
    in
    let redis_check =
      run_dependency ~name:"redis" ~required:false overrides.redis (fun () ->
          probe_redis config.Config.Api.agent.Config.Api.cache)
    in
    let openai_check =
      run_dependency ~name:"openai" ~required:false overrides.openai (fun () ->
          probe_openai config.Config.Api.agent)
    in
    let checks = [ postgres_check; qdrant_check; redis_check; openai_check ] in
    let status = summary_status checks in
    { status; checks }
end

module Worker = struct
  let summary ?postgres ~config ~api_config () =
    let overrides = current_overrides () in
    let postgres_check =
      run_dependency ~name:"postgres" ~required:true overrides.postgres
        (fun () ->
          probe_postgres ?existing_repo:postgres
            config.Config.Worker.database_url)
    in
    let qdrant_check =
      run_dependency ~name:"qdrant" ~required:true overrides.qdrant (fun () ->
          match Lazy.force api_config with
          | Error err -> `Error (Error.to_string_hum err)
          | Ok api -> probe_qdrant api.Config.Api.qdrant_url)
    in
    let openai_check =
      run_dependency ~name:"openai-embeddings" ~required:true
        overrides.embeddings (fun () ->
          probe_embeddings ~api_key:config.Config.Worker.openai_api_key
            ~endpoint:config.Config.Worker.openai_endpoint)
    in
    let checks = [ postgres_check; qdrant_check; openai_check ] in
    let status = summary_status checks in
    { status; checks }
end
