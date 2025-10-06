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
    id : int;
    white : string;
    black : string;
    result : string;
    year : int;
    event : string;
    eco : string option;
    opening : string;
    phases : string list;
    themes : string list;
    keywords : string list;
    white_elo : int option;
    black_elo : int option;
    synopsis : string;
  }

  let to_json t ~score ~vector_score ~keyword_score =
    let rating_fields =
      List.filter_map
        [ Option.map t.white_elo ~f:(fun value -> "white_elo", `Int value)
        ; Option.map t.black_elo ~f:(fun value -> "black_elo", `Int value) ]
        ~f:Fn.id
    in
    let eco_field = Option.map t.eco ~f:(fun code -> "eco", `String code) in
    `Assoc
      ( [ "game_id", `Int t.id
        ; "white", `String t.white
        ; "black", `String t.black
        ; "result", `String t.result
        ; "year", `Int t.year
        ; "event", `String t.event
        ; "opening", `String t.opening
        ; "phases", `List (List.map t.phases ~f:(fun phase -> `String phase))
        ; "themes", `List (List.map t.themes ~f:(fun theme -> `String theme))
        ; "keywords", `List (List.map t.keywords ~f:(fun keyword -> `String keyword))
        ; "score", `Float score
        ; "vector_score", `Float vector_score
        ; "keyword_score", `Float keyword_score
        ; "synopsis", `String t.synopsis ]
      @ rating_fields
      @ Option.to_list eco_field )
end

let dataset : Result.t list =
  [ { id = 1
    ; white = "Garry Kasparov"
    ; black = "Anatoly Karpov"
    ; result = "1-0"
    ; year = 1985
    ; event = "Tilburg"
    ; eco = Some "E69"
    ; opening = "kings_indian_defense"
    ; phases = [ "middlegame" ]
    ; themes = [ "king_attack"; "tactics" ]
    ; keywords = [ "indian"; "attack"; "sacrifice"; "kings" ]
    ; white_elo = Some 2710
    ; black_elo = Some 2610
    ; synopsis =
        "Kasparov sacrifices on h6 to crack Karpov's King's Indian fortress and converts the attack." }
  ; { id = 2
    ; white = "Viswanathan Anand"
    ; black = "Vladimir Kramnik"
    ; result = "0-1"
    ; year = 2008
    ; event = "World Championship"
    ; eco = Some "B12"
    ; opening = "caro_kann"
    ; phases = [ "middlegame" ]
    ; themes = [ "strategy"; "minority_attack" ]
    ; keywords = [ "caro"; "kann"; "minority"; "queenside" ]
    ; white_elo = Some 2780
    ; black_elo = Some 2781
    ; synopsis =
        "Kramnik neutralises Anand's initiative in the Caro-Kann and wins a technical rook endgame." }
  ; { id = 3
    ; white = "Judith Polgar"
    ; black = "Alexei Shirov"
    ; result = "1/2-1/2"
    ; year = 1997
    ; event = "Linares"
    ; eco = Some "C18"
    ; opening = "french_defense"
    ; phases = [ "endgame" ]
    ; themes = [ "queenside_majority"; "endgame" ]
    ; keywords = [ "french"; "endgame"; "draw"; "queenside" ]
    ; white_elo = Some 2710
    ; black_elo = Some 2725
    ; synopsis =
        "Polgar steers the French Tarrasch into a long endgame where a queenside majority holds the draw." }
  ; { id = 4
    ; white = "Magnus Carlsen"
    ; black = "Fabiano Caruana"
    ; result = "1-0"
    ; year = 2019
    ; event = "Wijk aan Zee"
    ; eco = Some "B90"
    ; opening = "sicilian_defense"
    ; phases = [ "middlegame"; "endgame" ]
    ; themes = [ "tactics"; "endgame" ]
    ; keywords = [ "sicilian"; "attack"; "endgame"; "carlsen" ]
    ; white_elo = Some 2835
    ; black_elo = Some 2820
    ; synopsis =
        "Carlsen out-calculates Caruana in a rich Sicilian Najdorf and converts a bishop pair endgame." }
  ; { id = 5
    ; white = "Hou Yifan"
    ; black = "Anna Muzychuk"
    ; result = "1-0"
    ; year = 2014
    ; event = "Women's Grand Prix"
    ; eco = Some "D37"
    ; opening = "queens_gambit"
    ; phases = [ "middlegame" ]
    ; themes = [ "positional"; "queenside_majority" ]
    ; keywords = [ "queens"; "gambit"; "positional"; "queenside" ]
    ; white_elo = Some 2630
    ; black_elo = Some 2550
    ; synopsis =
        "Hou Yifan presses a small edge in the Queen's Gambit and creates a winning queenside majority." }
  ]

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

let filter_matches result (filter : Query_intent.metadata_filter) =
  match filter.Query_intent.field with
  | "opening" -> String.equal result.Result.opening filter.value
  | "theme" -> List.mem result.themes filter.value ~equal:String.equal
  | "phase" -> List.mem result.phases filter.value ~equal:String.equal
  | "result" -> String.equal result.Result.result filter.value
  | _ -> true

let rating_matches result rating =
  let meets threshold value_opt =
    match threshold, value_opt with
    | None, _ -> true
    | Some min_value, Some actual -> actual >= min_value
    | Some _, None -> false
  in
  let meets_delta =
    match rating.Query_intent.max_rating_delta, result.Result.white_elo, result.Result.black_elo with
    | None, _, _ -> true
    | Some max_delta, Some w, Some b -> Int.abs (w - b) <= max_delta
    | Some _, _, _ -> false
  in
  meets rating.Query_intent.white_min result.Result.white_elo
  && meets rating.Query_intent.black_min result.Result.black_elo
  && meets_delta

let keyword_overlap plan result =
  let entry_keywords = Set.of_list (module String) result.Result.keywords in
  let matches = List.count plan.Query_intent.keywords ~f:(fun keyword -> Set.mem entry_keywords keyword) in
  let total = Int.max 1 (List.length plan.Query_intent.keywords) in
  Float.of_int matches /. Float.of_int total

let vector_score plan result =
  if List.is_empty plan.Query_intent.filters then 0.6
  else
    let matched =
      List.count plan.Query_intent.filters ~f:(fun filter -> filter_matches result filter)
    in
    0.4 +. (0.6 *. Float.of_int matched /. Float.of_int (List.length plan.Query_intent.filters))

let score_result plan result =
  let vector = Float.min 1.0 (vector_score plan result) in
  let keyword = keyword_overlap plan result in
  let combined = Hybrid_planner.scoring_weights Hybrid_planner.default ~vector ~keyword in
  (combined, vector, keyword)

let apply_plan plan =
  dataset
  |> List.filter ~f:(fun result ->
         List.for_all plan.Query_intent.filters ~f:(filter_matches result)
         && rating_matches result plan.Query_intent.rating)
  |> List.map ~f:(fun result ->
         let total, vector, keyword = score_result plan result in
         (result, total, vector, keyword))
  |> List.sort ~compare:(fun (_, a_score, _, _) (_, b_score, _, _) -> Float.compare b_score a_score)
  |> fun results -> List.take results plan.Query_intent.limit

let summarize_results results =
  let references =
    List.map results ~f:(fun (result, score, _, _) ->
        { Result_formatter.game_id = result.Result.id
        ; white = result.Result.white
        ; black = result.Result.black
        ; score })
  in
  Result_formatter.summarize references

let respond_plain_text ?(status = `OK) text =
  let headers = Cohttp.Header.init_with "Content-Type" "text/plain; charset=utf-8" in
  App.respond' ~code:status ~headers (`String text)

let respond_json ?(status = `OK) json =
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  App.respond' ~code:status ~headers (`String (Yojson.Safe.to_string json))

let health_handler _req = respond_plain_text ~status:`OK "ok"

let extract_question req =
  let open Lwt.Syntax in
  match Request.meth req with
  | `GET -> Lwt.return (Uri.get_query_param (Request.uri req) "q")
  | `POST ->
      let* body = App.string_of_body_exn req in
      let json_opt =
        try Some (Yojson.Safe.from_string body) with Yojson.Json_error _ -> None
      in
      Lwt.return
        (Option.bind json_opt ~f:(fun json ->
             Yojson.Safe.Util.(json |> member "question" |> to_string_option)))
  | _ -> Lwt.return None

let query_handler req =
  let open Lwt.Syntax in
  let* question_opt = extract_question req in
  match Option.bind question_opt ~f:(fun q -> if String.is_empty (String.strip q) then None else Some q) with
  | None ->
      let payload = `Assoc [ "error", `String "question parameter missing" ] in
      respond_json ~status:`Bad_request payload
  | Some question ->
      let plan = Query_intent.analyse { Query_intent.text = question } in
      let matches = apply_plan plan in
      let summary = summarize_results matches in
      let results_json =
        `List
          (List.map matches ~f:(fun (result, score, vector, keyword) ->
               Result.to_json result ~score ~vector_score:vector ~keyword_score:keyword))
      in
      let payload =
        `Assoc
          [ "question", `String question
          ; "plan", plan_to_json plan
          ; "summary", `String summary
          ; "results", results_json ]
      in
      respond_json payload

let routes =
  App.empty
  |> App.get "/health" health_handler
  |> App.get "/query" query_handler
  |> App.post "/query" query_handler

let determine_port () =
  match Stdlib.Sys.getenv_opt "CHESSMATE_API_PORT" with
  | Some value -> (match Int.of_string_opt value with Some port when port > 0 -> port | _ -> 8080)
  | None -> 8080

let () =
  let port = determine_port () in
  routes |> App.port port |> App.run_command
