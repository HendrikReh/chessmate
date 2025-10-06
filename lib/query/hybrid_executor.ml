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

open! Base

let phases_from_plan plan =
  plan.Query_intent.filters
  |> List.filter_map ~f:(fun filter ->
         if String.equal filter.Query_intent.field "phase" then Some filter.Query_intent.value else None)
  |> List.dedup_and_sort ~compare:String.compare

let themes_from_plan plan =
  plan.Query_intent.filters
  |> List.filter_map ~f:(fun filter ->
         if String.equal filter.Query_intent.field "theme" then Some filter.Query_intent.value else None)
  |> List.dedup_and_sort ~compare:String.compare

let eco_filter value =
  let value = String.uppercase (String.strip value) in
  match String.split value ~on:'-' with
  | [ start_code; end_code ] when not (String.is_empty start_code) && not (String.is_empty end_code) ->
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
  | "opening" -> String.equal (opening_slug summary) (String.lowercase filter.Query_intent.value)
  | "result" ->
      String.equal (Option.value summary.Repo_postgres.result ~default:"*") filter.Query_intent.value
  | "eco_range" -> eco_matches summary.Repo_postgres.eco_code filter.Query_intent.value
  | _ -> true

let rating_matches summary rating =
  let meets threshold value_opt =
    match threshold, value_opt with
    | None, _ -> true
    | Some min_value, Some actual -> actual >= min_value
    | Some _, None -> false
  in
  let meets_delta =
    match rating.Query_intent.max_rating_delta,
          summary.Repo_postgres.white_rating,
          summary.Repo_postgres.black_rating with
    | None, _, _ -> true
    | Some delta, Some white, Some black -> Int.abs (white - black) <= delta
    | Some _, _, _ -> false
  in
  meets rating.Query_intent.white_min summary.Repo_postgres.white_rating
  && meets rating.Query_intent.black_min summary.Repo_postgres.black_rating
  && meets_delta

let tokenize text =
  text
  |> String.lowercase
  |> String.map ~f:(fun ch -> if Char.is_alphanum ch then ch else ' ')
  |> String.split ~on:' '
  |> List.filter ~f:(fun token -> String.length token >= 3)

let summary_keyword_tokens summary =
  let sources =
    [ Some summary.Repo_postgres.white
    ; Some summary.Repo_postgres.black
    ; summary.Repo_postgres.event
    ; summary.Repo_postgres.opening_name
    ; summary.Repo_postgres.opening_slug ]
  in
  sources
  |> List.filter_map ~f:Fn.id
  |> List.concat_map ~f:tokenize
  |> List.dedup_and_sort ~compare:String.compare

let summary_tokens_with_vector summary vector_hit =
  match vector_hit with
  | None -> summary_keyword_tokens summary
  | Some hit -> Hybrid_planner.merge_keywords (summary_keyword_tokens summary) hit.Hybrid_planner.keywords

let keyword_overlap plan summary vector_hit =
  let summary_tokens =
    summary_tokens_with_vector summary vector_hit
    |> Set.of_list (module String)
  in
  let matches = List.count plan.Query_intent.keywords ~f:(fun kw -> Set.mem summary_tokens kw) in
  let total = Int.max 1 (List.length plan.Query_intent.keywords) in
  Float.of_int matches /. Float.of_int total

let fallback_vector_score plan summary =
  if not (rating_matches summary plan.Query_intent.rating) then 0.0
  else if List.is_empty plan.Query_intent.filters then 0.6
  else
    let matched =
      List.count plan.Query_intent.filters ~f:(fun filter -> filter_matches summary filter)
    in
    0.4 +. (0.6 *. Float.of_int matched /. Float.of_int (List.length plan.Query_intent.filters))

let vector_score plan summary vector_hit =
  match vector_hit with
  | Some hit when rating_matches summary plan.Query_intent.rating ->
      Hybrid_planner.normalize_vector_score hit.Hybrid_planner.score
  | Some _ -> 0.0
  | None -> fallback_vector_score plan summary

let score_result plan summary vector_hit =
  let vector = Float.min 1.0 (vector_score plan summary vector_hit) in
  let keyword = keyword_overlap plan summary vector_hit in
  let combined = Hybrid_planner.scoring_weights Hybrid_planner.default ~vector ~keyword in
  (combined, vector, keyword)

let combined_keywords plan summary vector_hit =
  let enriched_summary = summary_tokens_with_vector summary vector_hit in
  Hybrid_planner.merge_keywords plan.Query_intent.keywords enriched_summary

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
  phases : string list;
  themes : string list;
  keywords : string list;
}

type execution = {
  plan : Query_intent.plan;
  results : result list;
  warnings : string list;
}

let build_result plan summary plan_phases plan_themes vector_hit =
  let total_score, vector_score, keyword_score = score_result plan summary vector_hit in
  let phases = combined_phases plan_phases vector_hit in
  let themes = combined_themes plan_themes vector_hit in
  { summary
  ; total_score
  ; vector_score
  ; keyword_score
  ; phases
  ; themes
  ; keywords = combined_keywords plan summary vector_hit }

let execute ~fetch_games ~fetch_vector_hits plan =
  match fetch_games plan with
  | Error err -> Error err
  | Ok summaries ->
      let vector_hits, warnings =
        match fetch_vector_hits plan with
        | Ok hits -> hits, []
        | Error err ->
            let message = Error.to_string_hum err in
            [], [ Printf.sprintf "Vector search unavailable (%s)" message ]
      in
      let plan_phases = phases_from_plan plan in
      let plan_themes = themes_from_plan plan in
      let hit_index = Hybrid_planner.index_hits_by_game vector_hits in
      let scored_results =
        summaries
        |> List.map ~f:(fun summary ->
               let vector_hit = Map.find hit_index summary.Repo_postgres.id in
               build_result plan summary plan_phases plan_themes vector_hit)
        |> List.sort ~compare:(fun a b -> Float.compare b.total_score a.total_score)
      in
      let limited = List.take scored_results plan.Query_intent.limit in
      Or_error.return { plan; results = limited; warnings }
