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
open Chessmate
open Opium.Std

module Result = struct
  type t = {
    summary : Repo_postgres.game_summary;
    total_score : float;
    vector_score : float;
    keyword_score : float;
    phases : string list;
    themes : string list;
    keywords : string list;
  }

  let synopsis summary =
    let event = Option.value summary.Repo_postgres.event ~default:"Unspecified event" in
    let result = Option.value summary.Repo_postgres.result ~default:"*" in
    Printf.sprintf "%s vs %s — %s (%s)"
      summary.Repo_postgres.white
      summary.Repo_postgres.black
      event
      result

  let year summary =
    match summary.Repo_postgres.played_on with
    | Some date when String.length date >= 4 -> (
        match Int.of_string_opt (String.prefix date 4) with
        | Some year -> year
        | None -> 0 )
    | _ -> 0

  let opening_slug summary =
    Option.value summary.Repo_postgres.opening_slug ~default:"unknown_opening"

  let opening_name summary =
    match summary.Repo_postgres.opening_name, summary.Repo_postgres.opening_slug with
    | Some name, _ -> name
    | None, Some slug ->
        slug
        |> String.split ~on:'_'
        |> List.map ~f:String.capitalize
        |> String.concat ~sep:" "
    | None, None -> "Unknown opening"

  let to_json t =
    let summary = t.summary in
    `Assoc
      [ "game_id", `Int summary.Repo_postgres.id
      ; "white", `String summary.Repo_postgres.white
      ; "black", `String summary.Repo_postgres.black
      ; "result", `String (Option.value summary.Repo_postgres.result ~default:"*")
      ; "year", `Int (year summary)
      ; "event", `String (Option.value summary.Repo_postgres.event ~default:"Unspecified event")
      ; "opening_slug", `String (opening_slug summary)
      ; "opening_name", `String (opening_name summary)
      ; "eco"
        , Option.value_map summary.Repo_postgres.eco_code ~default:`Null ~f:(fun eco -> `String eco)
      ; "phases", `List (List.map t.phases ~f:(fun phase -> `String phase))
      ; "themes", `List (List.map t.themes ~f:(fun theme -> `String theme))
      ; "keywords", `List (List.map t.keywords ~f:(fun kw -> `String kw))
      ; "white_elo"
        , Option.value_map summary.Repo_postgres.white_rating ~default:`Null ~f:(fun value -> `Int value)
      ; "black_elo"
        , Option.value_map summary.Repo_postgres.black_rating ~default:`Null ~f:(fun value -> `Int value)
      ; "synopsis", `String (synopsis summary)
      ; "score", `Float t.total_score
      ; "vector_score", `Float t.vector_score
      ; "keyword_score", `Float t.keyword_score ]
end

let postgres_repo : Repo_postgres.t Or_error.t Lazy.t =
  lazy
    (match Stdlib.Sys.getenv_opt "DATABASE_URL" with
    | Some url when not (String.is_empty (String.strip url)) -> Repo_postgres.create url
    | _ -> Or_error.error_string "DATABASE_URL environment variable is required for chessmate-api")

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

let opening_slug summary = Result.opening_slug summary

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

let summary_keywords summary =
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

let keyword_overlap plan summary =
  let summary_tokens = Set.of_list (module String) (summary_keywords summary) in
  let matches = List.count plan.Query_intent.keywords ~f:(fun kw -> Set.mem summary_tokens kw) in
  let total = Int.max 1 (List.length plan.Query_intent.keywords) in
  Float.of_int matches /. Float.of_int total

let vector_score plan summary =
  if not (rating_matches summary plan.Query_intent.rating) then 0.0
  else if List.is_empty plan.Query_intent.filters then 0.6
  else
    let matched =
      List.count plan.Query_intent.filters ~f:(fun filter -> filter_matches summary filter)
    in
    0.4 +. (0.6 *. Float.of_int matched /. Float.of_int (List.length plan.Query_intent.filters))

let score_result plan summary =
  let vector = Float.min 1.0 (vector_score plan summary) in
  let keyword = keyword_overlap plan summary in
  let combined = Hybrid_planner.scoring_weights Hybrid_planner.default ~vector ~keyword in
  (combined, vector, keyword)

let combined_keywords plan summary =
  List.dedup_and_sort
    ~compare:String.compare
    (plan.Query_intent.keywords @ summary_keywords summary)

let build_result plan summary phases themes =
  let total_score, vector_score, keyword_score = score_result plan summary in
  { Result.summary
  ; total_score
  ; vector_score
  ; keyword_score
  ; phases
  ; themes
  ; keywords = combined_keywords plan summary }

let fetch_games plan =
  match Lazy.force postgres_repo with
  | Error err -> Error err
  | Ok repo -> Repo_postgres.search_games repo ~filters:plan.Query_intent.filters ~rating:plan.rating ~limit:plan.limit

let respond_plain_text ?(status = `OK) text =
  let headers = Cohttp.Header.init_with "Content-Type" "text/plain; charset=utf-8" in
  App.respond' ~code:status ~headers (`String text)

let respond_json ?(status = `OK) json =
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  App.respond' ~code:status ~headers (`String (Yojson.Safe.to_string json))

let health_handler _req = respond_plain_text "ok"

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
      (match fetch_games plan with
      | Error err ->
          respond_json ~status:`Internal_server_error
            (`Assoc [ "error", `String (Error.to_string_hum err) ])
      | Ok summaries ->
          let phases = phases_from_plan plan in
          let themes = themes_from_plan plan in
          let results = summaries |> List.map ~f:(fun summary -> build_result plan summary phases themes) in
          let sorted =
            List.sort results ~compare:(fun a b -> Float.compare b.total_score a.total_score)
          in
          let limited = List.take sorted plan.limit in
          let references =
            List.map limited ~f:(fun result ->
                { Result_formatter.game_id = result.summary.Repo_postgres.id
                ; white = result.summary.Repo_postgres.white
                ; black = result.summary.Repo_postgres.black
                ; score = result.total_score })
          in
          let summary_text =
            if List.is_empty limited then "No games matched the requested filters."
            else Result_formatter.summarize references
          in
          let results_json = List.map limited ~f:Result.to_json in
          let payload =
            `Assoc
              [ "question", `String question
              ; "plan", plan_to_json plan
              ; "summary", `String summary_text
              ; "results", `List results_json ]
          in
          respond_json payload)

let routes =
  App.empty
  |> App.get "/health" health_handler
  |> App.get "/query" query_handler
  |> App.post "/query" query_handler

let () =
  let port =
    match Stdlib.Sys.getenv_opt "CHESSMATE_API_PORT" with
    | Some value -> (match Int.of_string_opt value with Some port when port > 0 -> port | _ -> 8080)
    | None -> 8080
  in
  App.run_command (routes |> App.port port)
