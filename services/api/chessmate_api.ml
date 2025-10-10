(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search
Copyright (C) 2025 Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*)

(* Opium HTTP API handling `/query` requests. *)

open! Base
open Chessmate
open Opium.Std

module Result = struct
  type t = Hybrid_executor.result

  module Effort = Agents_gpt5_client.Effort
  module Usage = Agents_gpt5_client.Usage

  let summary (result : t) =
    let { Hybrid_executor.summary; _ } = result in
    summary

  let synopsis t =
    let summary = summary t in
    let event = Option.value summary.Repo_postgres.event ~default:"Unspecified event" in
    let result = Option.value summary.Repo_postgres.result ~default:"*" in
    Printf.sprintf "%s vs %s — %s (%s)"
      summary.Repo_postgres.white
      summary.Repo_postgres.black
      event
      result

  let year t =
    match (summary t).Repo_postgres.played_on with
    | Some date when String.length date >= 4 -> (
        match Int.of_string_opt (String.prefix date 4) with
        | Some year -> year
        | None -> 0 )
    | _ -> 0

  let opening_slug t =
    Option.value (summary t).Repo_postgres.opening_slug ~default:"unknown_opening"

  let opening_name t =
    match (summary t).Repo_postgres.opening_name, (summary t).Repo_postgres.opening_slug with
    | Some name, _ -> name
    | None, Some slug ->
        slug
        |> String.split ~on:'_'
        |> List.map ~f:String.capitalize
        |> String.concat ~sep:" "
    | None, None -> "Unknown opening"

  let usage_to_json usage =
    let token_field label value =
      match value with
      | None -> label, `Null
      | Some v -> label, `Int v
    in
    match usage with
    | None -> `Null
    | Some usage ->
        `Assoc
          [ token_field "input_tokens" usage.Usage.input_tokens
          ; token_field "output_tokens" usage.Usage.output_tokens
          ; token_field "reasoning_tokens" usage.Usage.reasoning_tokens ]

  let agent_score_json = function
    | None -> `Null
    | Some score -> `Float score

  let agent_effort_json = function
    | None -> `Null
    | Some effort -> `String (Effort.to_string effort)

  let agent_explanation_json = function
    | None -> `Null
    | Some text -> `String text

  let to_json t =
    let summary = summary t in
    `Assoc
      [ "game_id", `Int summary.Repo_postgres.id
      ; "white", `String summary.Repo_postgres.white
      ; "black", `String summary.Repo_postgres.black
      ; "result", `String (Option.value summary.Repo_postgres.result ~default:"*")
      ; "year", `Int (year t)
      ; "event", `String (Option.value summary.Repo_postgres.event ~default:"Unspecified event")
      ; "opening_slug", `String (opening_slug t)
      ; "opening_name", `String (opening_name t)
      ; "eco"
        , Option.value_map summary.Repo_postgres.eco_code ~default:`Null ~f:(fun eco -> `String eco)
      ; "phases", `List (List.map t.phases ~f:(fun phase -> `String phase))
      ; "themes", `List (List.map t.themes ~f:(fun theme -> `String theme))
      ; "keywords", `List (List.map t.keywords ~f:(fun kw -> `String kw))
      ; "white_elo"
        , Option.value_map summary.Repo_postgres.white_rating ~default:`Null ~f:(fun value -> `Int value)
      ; "black_elo"
        , Option.value_map summary.Repo_postgres.black_rating ~default:`Null ~f:(fun value -> `Int value)
      ; "synopsis", `String (synopsis t)
      ; "score", `Float t.total_score
      ; "vector_score", `Float t.vector_score
      ; "keyword_score", `Float t.keyword_score
      ; "agent_score", agent_score_json t.agent_score
      ; "agent_explanation", agent_explanation_json t.agent_explanation
      ; "agent_themes", `List (List.map t.agent_themes ~f:(fun theme -> `String theme))
      ; "agent_reasoning_effort", agent_effort_json t.agent_reasoning_effort
      ; "agent_usage", usage_to_json t.agent_usage ]
end

let api_config : Config.Api.t =
  match Config.Api.load () with
  | Ok config ->
      let agent_mode = if Option.is_some config.Config.Api.agent.api_key then "enabled" else "disabled" in
      let cache_mode =
        match config.Config.Api.agent.cache with
        | Config.Api.Agent_cache.Redis _ -> "redis"
        | Config.Api.Agent_cache.Memory _ -> "memory"
        | Config.Api.Agent_cache.Disabled -> "disabled"
      in
      Stdio.eprintf
        "[chessmate-api][config] port=%d database=present qdrant=present agent=%s cache=%s\n%!"
        config.port
        agent_mode
        cache_mode;
      config
  | Error err ->
      Stdio.eprintf "[chessmate-api][fatal] %s\n%!" (Error.to_string_hum err);
      Stdlib.exit 1

let postgres_repo : Repo_postgres.t Or_error.t Lazy.t =
  lazy (Repo_postgres.create api_config.database_url)

let agent_client : Agents_gpt5_client.t option Lazy.t =
  lazy
    (match api_config.Config.Api.agent.api_key with
    | None -> None
    | Some api_key ->
        let agent = api_config.Config.Api.agent in
        let create_client () =
          Agents_gpt5_client.create
            ~api_key
            ~endpoint:agent.endpoint
            ?model:agent.model
            ~default_effort:agent.reasoning_effort
            ?default_verbosity:agent.verbosity
            ()
        in
        match create_client () with
        | Ok client -> Some client
        | Error err ->
            Stdio.eprintf "[chessmate-api] agent disabled: %s\n%!" (Error.to_string_hum err);
            None)

let agent_cache : Agent_cache.t option Lazy.t =
  lazy
    (match api_config.Config.Api.agent.cache with
    | Config.Api.Agent_cache.Disabled -> None
    | Config.Api.Agent_cache.Memory { capacity } -> (
        let capacity_value = Option.value capacity ~default:1000 in
        Stdio.eprintf
          "[chessmate-api] agent cache enabled (mode=memory capacity=%d)\n%!"
          capacity_value;
        Some (Agent_cache.create ~capacity:capacity_value))
    | Config.Api.Agent_cache.Redis { url; namespace; ttl_seconds } -> (
        match Agent_cache.create_redis ?namespace ?ttl_seconds url with
        | Ok cache ->
            let namespace_log = Option.value namespace ~default:"chessmate:agent:" in
            let ttl_log = Option.value_map ttl_seconds ~default:"<none>" ~f:Int.to_string in
            Stdio.eprintf
              "[chessmate-api] agent cache enabled via redis (namespace=%s ttl=%s)\n%!"
              namespace_log ttl_log;
            Some cache
        | Error err ->
            Stdio.eprintf "[chessmate-api] redis agent cache disabled: %s\n%!"
              (Error.to_string_hum err);
            None))

let plan_to_json (plan : Query_intent.plan) =
  `Assoc
    [ "cleaned_text", `String plan.cleaned_text
    ; "limit", `Int plan.limit
    ; "filters"
      , `List
          (List.map plan.filters ~f:(fun filter ->
               `Assoc
                 [ "field", `String filter.Query_intent.field
                 ; "value", `String filter.Query_intent.value ]))
    ; "keywords", `List (List.map plan.keywords ~f:(fun kw -> `String kw))
    ; "rating"
      , `Assoc
          [ "white_min", Option.value_map plan.rating.white_min ~default:`Null ~f:(fun v -> `Int v)
          ; "black_min", Option.value_map plan.rating.black_min ~default:`Null ~f:(fun v -> `Int v)
          ; "max_rating_delta"
            , Option.value_map plan.rating.max_rating_delta ~default:`Null ~f:(fun v -> `Int v) ]
    ]


let fetch_games_impl plan =
  match Lazy.force postgres_repo with
  | Error err -> Error err
  | Ok repo -> Repo_postgres.search_games repo ~filters:plan.Query_intent.filters ~rating:plan.rating ~limit:plan.limit

let fetch_game_pgns_impl ids =
  match Lazy.force postgres_repo with
  | Error err -> Error err
  | Ok repo -> Repo_postgres.fetch_games_with_pgn repo ~ids

let fetch_vector_hits_impl plan =
  let vector = Hybrid_planner.query_vector plan in
  let filters = Hybrid_planner.build_payload_filters plan in
  let limit = Int.max (plan.Query_intent.limit * 3) 15 in
  Or_error.try_with (fun () -> Repo_qdrant.vector_search ~vector ~filters ~limit)
  |> Or_error.bind ~f:Fn.id
  |> Or_error.map ~f:Hybrid_planner.vector_hits_of_points

let fetch_games = fetch_games_impl
let fetch_vector_hits = fetch_vector_hits_impl

let respond_plain_text ?(status = `OK) text =
  let headers = Cohttp.Header.init_with "Content-Type" "text/plain; charset=utf-8" in
  App.respond' ~code:status ~headers (`String text)

let respond_json ?(status = `OK) json =
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  App.respond' ~code:status ~headers (`String (Yojson.Safe.to_string json))

let respond_yaml ?(status = `OK) text =
  let headers = Cohttp.Header.init_with "Content-Type" "application/yaml; charset=utf-8" in
  App.respond' ~code:status ~headers (`String text)

let source_root =
  lazy
    (Stdlib.Sys.getenv_opt "DUNE_SOURCEROOT"
    |> Option.value ~default:".")

let resolve_openapi_path () =
  match Stdlib.Sys.getenv_opt "CHESSMATE_OPENAPI_SPEC" with
  | Some raw when not (String.is_empty (String.strip raw)) -> raw
  | _ ->
      let root_candidate = Stdlib.Filename.concat (Lazy.force source_root) "docs/openapi.yaml" in
      if Stdlib.Sys.file_exists root_candidate then root_candidate else "docs/openapi.yaml"

let openapi_spec : ((string * string), string) Base.Result.t Lazy.t =
  lazy
    (let path = resolve_openapi_path () in
     match Or_error.try_with (fun () -> Stdio.In_channel.read_all path) with
     | Ok contents ->
         Stdio.eprintf "[chessmate-api][openapi] serving spec from %s\n%!" path;
         Ok (path, contents)
     | Error err ->
         let message = Error.to_string_hum err in
         Stdio.eprintf "[chessmate-api][openapi] failed to load %s (%s)\n%!" path message;
         Error message)

let openapi_handler _req =
  match Lazy.force openapi_spec with
  | Ok (_, spec) -> respond_yaml spec
  | Error message ->
      respond_json
        ~status:`Internal_server_error
        (`Assoc [ "error", `String ("OpenAPI specification unavailable: " ^ Sanitizer.sanitize_string message) ])

let health_handler _req = respond_plain_text "ok"

let metrics_handler _req =
  match Lazy.force postgres_repo with
  | Error err ->
      respond_plain_text ~status:`Internal_server_error (Sanitizer.sanitize_error err)
  | Ok repo ->
      let stats = Repo_postgres.pool_stats repo in
      let wait_ratio =
        if Int.(stats.capacity <= 0) then 0.0
        else Float.of_int stats.waiting /. Float.of_int stats.capacity
      in
      let body =
        Printf.sprintf
          "db_pool_capacity %d\n\
           db_pool_in_use %d\n\
           db_pool_available %d\n\
           db_pool_waiting %d\n\
           db_pool_wait_ratio %.3f\n"
          stats.capacity
          stats.in_use
          stats.available
          stats.waiting
          wait_ratio
      in
      respond_plain_text body

let extract_question req =
  let open Lwt.Syntax in
  match Request.meth req with
  | `GET -> Lwt.return (Uri.get_query_param (Request.uri req) "q")
  | `POST ->
      let* body = App.string_of_body_exn req in
      let json_opt = try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None in
      Lwt.return
        (Option.bind json_opt ~f:(fun json ->
             Yojson.Safe.Util.(json |> member "question" |> to_string_option)))
  | _ -> Lwt.return None

let query_handler req =
  let open Lwt.Syntax in
  let* question_opt = extract_question req in
  match Option.bind question_opt ~f:(fun q -> if String.is_empty (String.strip q) then None else Some q) with
  | None -> respond_json ~status:`Bad_request (`Assoc [ "error", `String "question parameter missing" ])
  | Some question ->
      let plan = Query_intent.analyse { Query_intent.text = question } in
      let agent_client_opt = Lazy.force agent_client in
      let agent_cache_opt = Lazy.force agent_cache in
      let fetch_game_pgns_opt =
        match agent_client_opt, agent_cache_opt with
        | None, None -> None
        | Some _, _ -> Some fetch_game_pgns_impl
        | None, Some _ -> Some fetch_game_pgns_impl
      in
      (match
         Hybrid_executor.execute
           ~fetch_games
           ~fetch_vector_hits
           ?fetch_game_pgns:fetch_game_pgns_opt
           ?agent_client:agent_client_opt
           ?agent_cache:agent_cache_opt
           plan
      with
      | Error err ->
          respond_json ~status:`Internal_server_error
            (`Assoc [ "error", `String (Sanitizer.sanitize_error err) ])
      | Ok execution ->
          List.iter execution.Hybrid_executor.warnings ~f:(fun warning ->
              Stdio.eprintf "[chessmate-api] warning: %s\n%!" warning);
          let results = execution.Hybrid_executor.results in
          let references =
            List.map results ~f:(fun result ->
                let summary = Result.summary result in
                { Result_formatter.game_id = summary.Repo_postgres.id
                ; white = summary.Repo_postgres.white
                ; black = summary.Repo_postgres.black
                ; score = result.total_score })
          in
          let summary_text =
            if List.is_empty results then "No games matched the requested filters."
            else Result_formatter.summarize references
          in
          let results_json = List.map results ~f:Result.to_json in
          let warning_field =
            match execution.Hybrid_executor.warnings with
            | [] -> []
            | _ ->
                [ "warnings"
                , `List (List.map execution.Hybrid_executor.warnings ~f:(fun warning -> `String warning)) ]
          in
          let payload =
            `Assoc
              ( [ "question", `String question
                ; "plan", plan_to_json execution.Hybrid_executor.plan
                ; "summary", `String summary_text
                ; "results", `List results_json ]
              @ warning_field )
          in
          respond_json payload)

let routes =
  App.empty
  |> App.get "/health" health_handler
  |> App.get "/metrics" metrics_handler
  |> App.get "/openapi.yaml" openapi_handler
  |> App.get "/query" query_handler
  |> App.post "/query" query_handler

let run_with_shutdown app =
  match App.run_command' app with
  | `Error -> Stdlib.exit 1
  | `Not_running -> ()
  | `Ok server ->
      let open Lwt.Syntax in
      let shutdown_signal, notify = Lwt.wait () in
      let register_signal name signal =
        Stdlib.Sys.set_signal signal
          (Stdlib.Sys.Signal_handle (fun _ ->
               Stdio.eprintf "[chessmate-api][shutdown] %s received, terminating\n%!" name;
               if Lwt.is_sleeping shutdown_signal then Lwt.wakeup_later notify name))
      in
      register_signal "SIGINT" Stdlib.Sys.sigint;
      register_signal "SIGTERM" Stdlib.Sys.sigterm;
      let shutdown reason =
        Stdio.eprintf "[chessmate-api][shutdown] stopping server (%s)\n%!" reason;
        Lwt.cancel server;
        let* () =
          Lwt.catch
            (fun () -> server)
            (function
              | Lwt.Canceled -> Lwt.return_unit
              | exn ->
                  Stdio.eprintf "[chessmate-api][shutdown] exception: %s\n%!" (Exn.to_string exn);
                  Lwt.return_unit)
        in
        Lwt.return_unit
      in
      Lwt_main.run (Lwt.pick [ server; let* reason = shutdown_signal in shutdown reason ])

let () =
  run_with_shutdown (routes |> App.port api_config.Config.Api.port)
