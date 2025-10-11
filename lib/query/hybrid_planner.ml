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

(** Translate analysed query intent into Postgres predicates, optional Qdrant
    payload filters, and deterministic vector placeholders plus scoring weights.
*)

open! Base
module Util = Yojson.Safe.Util

let vector_dimension = 8
let clamp_float value ~min ~max = Float.min max (Float.max min value)

type t = { vector_weight : float; keyword_weight : float }

let default = { vector_weight = 0.7; keyword_weight = 0.3 }

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

let hash_component token index =
  let hashed = Hashtbl.hash (token, index) |> Int.abs in
  let bucket = Int.rem hashed 10_000 in
  Float.of_int bucket /. 10_000.0

let query_vector plan =
  let tokens =
    if List.is_empty plan.Query_intent.keywords then [ plan.cleaned_text ]
    else plan.Query_intent.keywords
  in
  List.init vector_dimension ~f:(fun index ->
      match tokens with
      | [] -> 0.0
      | _ ->
          let total =
            List.fold tokens ~init:0.0 ~f:(fun acc token ->
                acc +. hash_component token index)
          in
          clamp_float
            (total /. Float.of_int (List.length tokens))
            ~min:0.0 ~max:1.0)

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

let vector_hits_of_points points =
  points
  |> List.filter_map ~f:vector_hit_of_point
  |> List.dedup_and_sort ~compare:(fun a b -> Int.compare a.game_id b.game_id)

let index_hits_by_game hits =
  List.fold hits
    ~init:(Map.empty (module Int))
    ~f:(fun acc hit -> Map.set acc ~key:hit.game_id ~data:hit)

let merge_keywords base additional =
  List.rev_append base additional
  |> List.map ~f:String.lowercase
  |> List.dedup_and_sort ~compare:String.compare

let merge_phases base additional = merge_keywords base additional
let merge_themes base additional = merge_keywords base additional
