(** Translate analysed query intent into Postgres predicates, optional Qdrant
    payload filters, and query embeddings (with deterministic fallbacks) plus
    scoring weights. *)

open! Base
module Util = Yojson.Safe.Util
module Query_embedding_provider = Query_embedding_provider

let clamp_float value ~min ~max = Float.min max (Float.max min value)

type t = { vector_weight : float; keyword_weight : float }

let default = { vector_weight = 0.75; keyword_weight = 0.25 }

let scoring_weights t ~vector ~keyword =
  (t.vector_weight *. vector) +. (t.keyword_weight *. keyword)

let match_clause key value =
  `Assoc
    [ ("key", `String key); ("match", `Assoc [ ("value", `String value) ]) ]

let range_clause key ~gte =
  `Assoc [ ("key", `String key); ("range", `Assoc [ ("gte", `Int gte) ]) ]

let normalize_slug value = String.lowercase (String.strip value)

let convert_filter (filter : Query_intent.metadata_filter) =
  match String.lowercase filter.field with
  | "opening" ->
      Some (match_clause "opening_slug" (normalize_slug filter.value))
  | "phase" -> Some (match_clause "phases" (normalize_slug filter.value))
  | "theme" -> Some (match_clause "themes" (normalize_slug filter.value))
  | "result" -> Some (match_clause "result" (String.strip filter.value))
  | "eco_range" -> None (* ECO handling is delegated to Postgres for now. *)
  | _ -> None

let rating_clauses rating =
  let clauses = ref [] in
  (match rating.Query_intent.white_min with
  | Some min -> clauses := range_clause "white_elo" ~gte:min :: !clauses
  | None -> ());
  (match rating.Query_intent.black_min with
  | Some min -> clauses := range_clause "black_elo" ~gte:min :: !clauses
  | None -> ());
  List.rev !clauses

let build_payload_filters plan =
  let converted_filters =
    plan.Query_intent.filters |> List.filter_map ~f:convert_filter
  in
  let rating_filters = rating_clauses plan.Query_intent.rating in
  let combined = converted_filters @ rating_filters in
  if List.is_empty combined then None else Some combined

type query_vector_source = Query_embedding_provider.source =
  | Embedding_service
  | Deterministic_fallback

type query_vector = Query_embedding_provider.fetch_result = {
  vector : float list;
  source : query_vector_source;
  warnings : string list;
}

let query_vector plan =
  Query_embedding_provider.fetch (Query_embedding_provider.current ()) plan

let normalize_vector_score score =
  if Float.is_nan score || not (Float.is_finite score) then 0.0
  else clamp_float score ~min:0.0 ~max:1.0

type vector_hit = {
  game_id : int;
  score : float;
  phases : string list;
  themes : string list;
  keywords : string list;
}

let int_of_json = function
  | `Int value -> Some value
  | `Intlit value -> Int.of_string_opt value
  | `Float value -> Some (Float.to_int value)
  | `String value -> Int.of_string_opt value
  | _ -> None

let string_list_of_json json =
  match json with
  | `Null -> []
  | `String value -> [ value ]
  | `List items ->
      items
      |> List.filter_map ~f:(function `String value -> Some value | _ -> None)
  | _ -> []

let vector_hit_of_point (point : Repo_qdrant.scored_point) =
  match point.payload with
  | None -> None
  | Some payload -> (
      match int_of_json (Util.member "game_id" payload) with
      | None -> None
      | Some game_id ->
          let phases = Util.member "phases" payload |> string_list_of_json in
          let themes = Util.member "themes" payload |> string_list_of_json in
          let keywords =
            Util.member "keywords" payload |> string_list_of_json
          in
          Some { game_id; score = point.score; phases; themes; keywords })

let merge_keywords base additional =
  List.rev_append base additional
  |> List.map ~f:String.lowercase
  |> List.dedup_and_sort ~compare:String.compare

let merge_phases base additional = merge_keywords base additional
let merge_themes base additional = merge_keywords base additional

let combine_hits existing incoming =
  {
    game_id = existing.game_id;
    score = Float.max existing.score incoming.score;
    phases = merge_phases existing.phases incoming.phases;
    themes = merge_themes existing.themes incoming.themes;
    keywords = merge_keywords existing.keywords incoming.keywords;
  }

let vector_hits_of_points points =
  let by_game =
    List.fold points
      ~init:(Map.empty (module Int))
      ~f:(fun acc point ->
        match vector_hit_of_point point with
        | None -> acc
        | Some hit ->
            let combined =
              match Map.find acc hit.game_id with
              | None -> hit
              | Some existing -> combine_hits existing hit
            in
            Map.set acc ~key:hit.game_id ~data:combined)
  in
  Map.data by_game

let index_hits_by_game hits =
  List.fold hits
    ~init:(Map.empty (module Int))
    ~f:(fun acc hit -> Map.set acc ~key:hit.game_id ~data:hit)
