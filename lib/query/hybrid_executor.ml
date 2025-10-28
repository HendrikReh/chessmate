(** Execute the hybrid retrieval plan by combining Postgres metadata, optional
    vector hits, and GPT-5 scores into ranked results. *)

open! Base
module Agent_eval = Agent_evaluator
module GPT = Agents_gpt5_client
module Api_metrics = Api_metrics

module Int_map = Map.M (Int)
type 'a int_map = 'a Int_map.t

let phases_from_plan plan =
  plan.Query_intent.filters
  |> List.filter_map ~f:(fun filter ->
         if String.equal filter.Query_intent.field "phase" then
           Some filter.Query_intent.value
         else None)
  |> List.dedup_and_sort ~compare:String.compare

let themes_from_plan plan =
  plan.Query_intent.filters
  |> List.filter_map ~f:(fun filter ->
         if String.equal filter.Query_intent.field "theme" then
           Some filter.Query_intent.value
         else None)
  |> List.dedup_and_sort ~compare:String.compare

let eco_filter value =
  let value = String.uppercase (String.strip value) in
  match String.split value ~on:'-' with
  | [ start_code; end_code ]
    when (not (String.is_empty start_code)) && not (String.is_empty end_code) ->
      `Range (start_code, end_code)
  | _ -> `Exact value

let eco_matches eco_value filter_value =
  match eco_value with
  | None -> false
  | Some eco -> (
      match eco_filter filter_value with
      | `Exact single -> String.equal (String.uppercase eco) single
      | `Range (start_code, end_code) ->
          let eco = String.uppercase eco in
          String.(eco >= start_code && eco <= end_code))

let opening_slug summary =
  Option.value summary.Repo_postgres.opening_slug ~default:"unknown_opening"

let filter_matches summary (filter : Query_intent.metadata_filter) =
  match String.lowercase filter.Query_intent.field with
  | "opening" ->
      String.equal (opening_slug summary)
        (String.lowercase filter.Query_intent.value)
  | "result" ->
      String.equal
        (Option.value summary.Repo_postgres.result ~default:"*")
        filter.Query_intent.value
  | "eco_range" ->
      eco_matches summary.Repo_postgres.eco_code filter.Query_intent.value
  | _ -> true

let rating_matches summary rating =
  let meets threshold value_opt =
    match (threshold, value_opt) with
    | None, _ -> true
    | Some min_value, Some actual -> actual >= min_value
    | Some _, None -> false
  in
  let meets_delta =
    match
      ( rating.Query_intent.max_rating_delta,
        summary.Repo_postgres.white_rating,
        summary.Repo_postgres.black_rating )
    with
    | None, _, _ -> true
    | Some delta, Some white, Some black -> Int.abs (white - black) <= delta
    | Some _, _, _ -> false
  in
  meets rating.Query_intent.white_min summary.Repo_postgres.white_rating
  && meets rating.Query_intent.black_min summary.Repo_postgres.black_rating
  && meets_delta

let tokenize_sources sources =
  let buffer = Stdlib.Buffer.create 32 in
  let flush acc =
    if Stdlib.Buffer.length buffer >= 3 then (
      let token = Stdlib.Buffer.contents buffer in
      Stdlib.Buffer.clear buffer;
      Set.add acc token)
    else (
      Stdlib.Buffer.clear buffer;
      acc)
  in
  let push_char acc ch =
    let lower = Char.lowercase ch in
    if Char.is_alphanum lower then (
      Stdlib.Buffer.add_char buffer lower;
      acc)
    else flush acc
  in
  let acc =
    List.fold sources ~init:(Set.empty (module String)) ~f:(fun acc source ->
        let acc = String.fold source ~init:acc ~f:push_char in
        flush acc)
  in
  let acc = flush acc in
  Set.to_list acc

let summary_keyword_tokens summary =
  let sources =
    [
      Some summary.Repo_postgres.white;
      Some summary.Repo_postgres.black;
      summary.Repo_postgres.event;
      summary.Repo_postgres.opening_name;
      summary.Repo_postgres.opening_slug;
    ]
  in
  sources |> List.filter_map ~f:Fn.id |> tokenize_sources

let summary_tokens_with_vector summary_tokens vector_hit =
  match vector_hit with
  | None -> summary_tokens
  | Some hit ->
      Hybrid_planner.merge_keywords summary_tokens hit.Hybrid_planner.keywords

let keyword_overlap plan token_set =
  let matches =
    List.count plan.Query_intent.keywords ~f:(fun kw -> Set.mem token_set kw)
  in
  let total = Int.max 1 (List.length plan.Query_intent.keywords) in
  Float.of_int matches /. Float.of_int total

let fallback_vector_score plan summary ~rating_match =
  if not rating_match then 0.0
  else if List.is_empty plan.Query_intent.filters then 0.6
  else
    let matched =
      List.count plan.Query_intent.filters ~f:(fun filter ->
          filter_matches summary filter)
    in
    0.4
    +. 0.6 *. Float.of_int matched
       /. Float.of_int (List.length plan.Query_intent.filters)

let vector_score plan summary vector_hit ~rating_match =
  match vector_hit with
  | Some hit when rating_match ->
      Hybrid_planner.normalize_vector_score hit.Hybrid_planner.score
  | Some _ -> 0.0
  | None -> fallback_vector_score plan summary ~rating_match

let score_result plan summary vector_hit summary_tokens ~rating_match =
  let vector =
    Float.min 1.0 (vector_score plan summary vector_hit ~rating_match)
  in
  let keyword =
    keyword_overlap plan (Set.of_list (module String) summary_tokens)
  in
  let combined =
    Hybrid_planner.scoring_weights Hybrid_planner.default ~vector ~keyword
  in
  (combined, vector, keyword)

let combined_keywords plan summary_tokens =
  Hybrid_planner.merge_keywords plan.Query_intent.keywords summary_tokens

let combined_phases plan_phases vector_hit =
  match vector_hit with
  | Some hit when not (List.is_empty hit.Hybrid_planner.phases) ->
      Hybrid_planner.merge_phases plan_phases hit.Hybrid_planner.phases
  | _ -> plan_phases

let combined_themes plan_themes vector_hit =
  match vector_hit with
  | Some hit when not (List.is_empty hit.Hybrid_planner.themes) ->
      Hybrid_planner.merge_themes plan_themes hit.Hybrid_planner.themes
  | _ -> plan_themes

type result = {
  summary : Repo_postgres.game_summary;
  total_score : float;
  vector_score : float;
  keyword_score : float;
  agent_score : float option;
  agent_explanation : string option;
  agent_themes : string list;
  agent_reasoning_effort : GPT.Effort.t option;
  agent_usage : GPT.Usage.t option;
  phases : string list;
  themes : string list;
  keywords : string list;
}

type agent_status = Agent_disabled | Agent_enabled | Agent_circuit_open

let agent_status_to_string = function
  | Agent_disabled -> "disabled"
  | Agent_enabled -> "enabled"
  | Agent_circuit_open -> "circuit_open"

type execution = {
  plan : Query_intent.plan;
  results : result list;
  total : int;
  has_more : bool;
  warnings : string list;
  agent_status : agent_status;
}

let default_agent_candidate_multiplier = 5
let default_agent_candidate_max = 25

let build_result plan summary plan_phases plan_themes vector_hit agent_eval =
  let rating_match = rating_matches summary plan.Query_intent.rating in
  let summary_tokens_base = summary_keyword_tokens summary in
  let summary_tokens =
    summary_tokens_with_vector summary_tokens_base vector_hit
  in
  let base_total, vector_score, keyword_score =
    score_result plan summary vector_hit summary_tokens ~rating_match
  in
  let phases = combined_phases plan_phases vector_hit in
  let themes = combined_themes plan_themes vector_hit in
  let agent_score, agent_explanation, agent_themes, agent_effort, agent_usage =
    match agent_eval with
    | None -> (None, None, [], None, None)
    | Some eval ->
        ( Some (Float.clamp_exn ~min:0.0 ~max:1.0 eval.Agent_eval.score),
          eval.Agent_eval.explanation,
          eval.Agent_eval.themes,
          Some eval.Agent_eval.reasoning_effort,
          eval.Agent_eval.usage )
  in
  let combined_themes = Hybrid_planner.merge_themes themes agent_themes in
  let combined_total =
    match agent_score with
    | None -> base_total
    | Some score -> Float.min 1.0 ((0.6 *. base_total) +. (0.4 *. score))
  in
  {
    summary;
    total_score = combined_total;
    vector_score;
    keyword_score;
    agent_score;
    agent_explanation;
    agent_themes;
    agent_reasoning_effort = agent_effort;
    agent_usage;
    phases;
    themes = combined_themes;
    keywords = combined_keywords plan summary_tokens;
  }

type metadata = {
  summaries : Repo_postgres.game_summary list;
  total : int;
  plan_phases : string list;
  plan_themes : string list;
  hit_index : Hybrid_planner.vector_hit int_map;
  warnings : string list;
}

let collect_metadata ~plan ~fetch_games ~fetch_vector_hits =
  match fetch_games plan with
  | Error err -> Error err
  | Ok { Repo_postgres.games = summaries; total } ->
      let vector_hits, warnings =
        match fetch_vector_hits plan with
        | Ok (hits, warnings) -> (hits, warnings)
        | Error err ->
            let message = Error.to_string_hum err in
            ([], [ Printf.sprintf "Vector search unavailable (%s)" message ])
      in
      let plan_phases = phases_from_plan plan in
      let plan_themes = themes_from_plan plan in
      let hit_index = Hybrid_planner.index_hits_by_game vector_hits in
      Or_error.return
        { summaries; total; plan_phases; plan_themes; hit_index; warnings }

type agent_outcome = {
  evaluations : Agent_eval.evaluation int_map;
  status : agent_status;
  warnings : string list;
}

let empty_agent_outcome status warnings =
  { evaluations = Map.empty (module Int); status; warnings }

let evaluate_agent ~plan ~summaries ~fetch_game_pgns ~agent_evaluator
    ~agent_client ~agent_cache ~agent_timeout_seconds
    ~agent_candidate_multiplier ~agent_candidate_max ~agent_circuit_breaker =
  match (fetch_game_pgns, (agent_evaluator, agent_client)) with
  | None, _ | _, (None, None) -> empty_agent_outcome Agent_disabled []
  | Some fetch_pgns, evaluators -> (
      let candidate_count =
        Int.min agent_candidate_max
          (Int.max plan.Query_intent.limit
             (plan.Query_intent.limit * agent_candidate_multiplier))
      in
      let candidate_summaries = List.take summaries candidate_count in
      if List.is_empty candidate_summaries then (
        Agent_circuit_breaker.record_success agent_circuit_breaker;
        empty_agent_outcome Agent_enabled [])
      else
        let ids =
          List.map candidate_summaries ~f:(fun summary ->
              summary.Repo_postgres.id)
        in
        match fetch_pgns ids with
        | Error err ->
            Agent_circuit_breaker.record_failure agent_circuit_breaker;
            empty_agent_outcome Agent_enabled
              [
                Printf.sprintf "Agent disabled (PGN fetch failed): %s"
                  (Error.to_string_hum err);
              ]
        | Ok id_pgns -> (
            let pgn_map =
              List.fold id_pgns
                ~init:(Map.empty (module Int))
                ~f:(fun acc (id, pgn) -> Map.set acc ~key:id ~data:pgn)
            in
            let candidates_with_keys =
              candidate_summaries
              |> List.filter_map ~f:(fun summary ->
                     match Map.find pgn_map summary.Repo_postgres.id with
                     | Some pgn ->
                         let key =
                           Agent_cache.key_of_plan ~plan ~summary ~pgn
                         in
                         Some (summary, pgn, key)
                     | None -> None)
            in
            let cached_map, pending =
              match agent_cache with
              | None -> (Map.empty (module Int), candidates_with_keys)
              | Some cache ->
                  List.fold candidates_with_keys
                    ~init:(Map.empty (module Int), [])
                    ~f:(fun (cache_hits, missing) (summary, pgn, key) ->
                      match Agent_cache.find cache key with
                      | Some eval ->
                          Api_metrics.record_agent_cache_hit ();
                          let cache_hits =
                            Map.set cache_hits ~key:summary.Repo_postgres.id
                              ~data:eval
                          in
                          (cache_hits, missing)
                      | None ->
                          Api_metrics.record_agent_cache_miss ();
                          (cache_hits, (summary, pgn, key) :: missing))
            in
            let cached_messages =
              match agent_cache with
              | Some _ when not (Map.is_empty cached_map) ->
                  [
                    Printf.sprintf "Agent cache hit for %d candidates"
                      (Map.length cached_map);
                  ]
              | _ -> []
            in
            let pending = List.rev pending in
            if List.is_empty pending then (
              Agent_circuit_breaker.record_success agent_circuit_breaker;
              {
                evaluations = cached_map;
                status = Agent_enabled;
                warnings = cached_messages;
              })
            else if
              not (Agent_circuit_breaker.should_allow agent_circuit_breaker)
            then
              {
                evaluations = cached_map;
                status = Agent_circuit_open;
                warnings =
                  cached_messages
                  @ [ "Agent circuit breaker open; using cached evaluations" ];
              }
            else
              let unresolved =
                List.map pending ~f:(fun (summary, pgn, _) -> (summary, pgn))
              in
              let evaluate candidates =
                match evaluators with
                | Some custom, _ -> custom ~plan ~candidates
                | None, Some client ->
                    Agent_eval.evaluate ~timeout_seconds:agent_timeout_seconds
                      ~client ~plan ~candidates
                | None, None -> Or_error.return []
              in
              match evaluate unresolved with
              | Error err ->
                  Agent_circuit_breaker.record_failure agent_circuit_breaker;
                  {
                    evaluations = cached_map;
                    status = Agent_enabled;
                    warnings =
                      cached_messages
                      @ [
                          Printf.sprintf "Agent evaluation failed: %s"
                            (Error.to_string_hum err);
                        ];
                  }
              | Ok evaluations ->
                  Agent_circuit_breaker.record_success agent_circuit_breaker;
                  let eval_map =
                    List.fold evaluations
                      ~init:(Map.empty (module Int))
                      ~f:(fun acc eval ->
                        Map.set acc ~key:eval.Agent_eval.game_id ~data:eval)
                  in
                  (match agent_cache with
                  | Some cache ->
                      List.iter pending ~f:(fun (summary, _, key) ->
                          match Map.find eval_map summary.Repo_postgres.id with
                          | Some eval -> Agent_cache.store cache key eval
                          | None -> ())
                  | None -> ());
                  let merged_map =
                    Map.fold eval_map ~init:cached_map ~f:(fun ~key ~data acc ->
                        Map.set acc ~key ~data)
                  in
                  let usage_messages =
                    match evaluations with
                    | [] -> []
                    | eval :: _ ->
                        let effort =
                          GPT.Effort.to_string eval.Agent_eval.reasoning_effort
                        in
                        let usage_details =
                          match eval.Agent_eval.usage with
                          | None -> []
                          | Some usage ->
                              let open GPT.Usage in
                              [
                                ("input", usage.input_tokens);
                                ("output", usage.output_tokens);
                                ("reasoning", usage.reasoning_tokens);
                              ]
                              |> List.filter_map ~f:(fun (label, value) ->
                                     Option.map value ~f:(fun v ->
                                         Printf.sprintf "%s=%d" label v))
                        in
                        let usage_suffix =
                          if List.is_empty usage_details then ""
                          else
                            Printf.sprintf " (%s)"
                              (String.concat ~sep:", " usage_details)
                        in
                        [
                          Printf.sprintf
                            "Agent evaluated %d candidates (effort=%s)%s"
                            (List.length evaluations) effort usage_suffix;
                        ]
                  in
                  {
                    evaluations = merged_map;
                    status = Agent_enabled;
                    warnings = cached_messages @ usage_messages;
                  }))

let score_results plan metadata agent_map =
  metadata.summaries
  |> List.map ~f:(fun summary ->
         let vector_hit =
           Map.find metadata.hit_index summary.Repo_postgres.id
         in
         let agent_eval = Map.find agent_map summary.Repo_postgres.id in
         build_result plan summary metadata.plan_phases metadata.plan_themes
           vector_hit agent_eval)
  |> List.sort ~compare:(fun a b -> Float.compare b.total_score a.total_score)

let execute ~fetch_games ~fetch_vector_hits ?fetch_game_pgns ?agent_evaluator
    ?agent_client ?agent_cache ?agent_timeout_seconds
    ?(agent_candidate_multiplier = default_agent_candidate_multiplier)
    ?(agent_candidate_max = default_agent_candidate_max) ~agent_circuit_breaker
    plan =
  match collect_metadata ~plan ~fetch_games ~fetch_vector_hits with
  | Error err -> Error err
  | Ok metadata ->
      let agent_outcome =
        evaluate_agent ~plan ~summaries:metadata.summaries ~fetch_game_pgns
          ~agent_evaluator ~agent_client ~agent_cache ~agent_timeout_seconds
          ~agent_candidate_multiplier ~agent_candidate_max
          ~agent_circuit_breaker
      in
      let warnings = metadata.warnings @ agent_outcome.warnings in
      let scored_results =
        score_results plan metadata agent_outcome.evaluations
      in
      let limited = List.take scored_results plan.Query_intent.limit in
      let returned = List.length limited in
      let has_more =
        Int.(plan.Query_intent.offset + returned < metadata.total)
      in
      Or_error.return
        {
          plan;
          results = limited;
          total = metadata.total;
          has_more;
          warnings;
          agent_status = agent_outcome.status;
        }
