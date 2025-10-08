(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search
    Copyright (C) 2025 Hendrik Reh

    GPL v3
*)

open! Base

let ( let* ) t f = Or_error.bind t ~f

module Effort = Agents_gpt5_client.Effort
module Verbosity = Agents_gpt5_client.Verbosity
module Message = Agents_gpt5_client.Message
module Role = Agents_gpt5_client.Role
module Response_format = Agents_gpt5_client.Response_format
module Usage = Agents_gpt5_client.Usage
module Response = Agents_gpt5_client.Response

type evaluation = {
  game_id : int;
  score : float;
  explanation : string option;
  themes : string list;
  reasoning_effort : Effort.t;
  usage : Usage.t option;
}

let max_candidates = 25
let max_pgn_chars = 3000

let truncate_pgn pgn =
  if String.length pgn <= max_pgn_chars then pgn
  else String.prefix pgn max_pgn_chars ^ "\n... [PGN truncated]"

let effort_for_plan (plan : Query_intent.plan) =
  let has_theme_filter =
    List.exists plan.Query_intent.filters ~f:(fun filter ->
        String.equal (String.lowercase filter.Query_intent.field) "theme")
  in
  if has_theme_filter || List.length plan.Query_intent.keywords >= 4 then Effort.High else Effort.Medium

let verbosity_for_plan (plan : Query_intent.plan) =
  if List.length plan.Query_intent.filters <= 1 && List.length plan.Query_intent.keywords <= 2 then Some Verbosity.Low
  else Some Verbosity.Medium

let build_candidate_block (summary : Repo_postgres.game_summary) pgn =
  let result = Option.value summary.Repo_postgres.result ~default:"*" in
  let played_on = Option.value summary.Repo_postgres.played_on ~default:"Unknown date" in
  let eco = Option.value summary.Repo_postgres.eco_code ~default:"Unknown ECO" in
  let opening = Option.value summary.Repo_postgres.opening_name ~default:"Unknown opening" in
  let rating rating_opt = Option.value_map rating_opt ~default:"?" ~f:Int.to_string in
  let ratings =
    Printf.sprintf "%s vs %s" (rating summary.Repo_postgres.white_rating) (rating summary.Repo_postgres.black_rating)
  in
  Printf.sprintf
    {|Game ID: %d
White: %s
Black: %s
Result: %s
Opening: %s (%s)
Played on: %s
Ratings (White | Black): %s
PGN:
%s|}
    summary.Repo_postgres.id
    summary.Repo_postgres.white
    summary.Repo_postgres.black
    result
    opening
    eco
    played_on
    ratings
    (truncate_pgn pgn)

let build_user_message (plan : Query_intent.plan) candidates =
  let instructions =
    {|Evaluate each candidate chess game for the user's question. For every game, assign a relevance score between 0.0 and 1.0 (two decimal precision) and explain why it matches or fails the request. Scores must reflect confidence in the match, where 1.0 represents a perfect match and 0.0 represents not relevant.

Return JSON that conforms to the provided schema with one entry per evaluated game. If a game lacks sufficient information to judge relevance, return a score of 0.0 and explain the uncertainty.

User question: |}
  in
  let question_line = plan.Query_intent.cleaned_text in
  let candidate_blocks =
    candidates
    |> List.map ~f:(fun (summary, pgn) -> build_candidate_block summary pgn)
    |> String.concat ~sep:"\n\n---\n\n"
  in
  Printf.sprintf "%s%s\n\nCandidates:\n\n%s" instructions question_line candidate_blocks

let response_schema =
  Yojson.Safe.from_string
    {|{
        "name": "agent_output",
        "schema": {
          "type": "object",
          "additionalProperties": false,
          "required": ["evaluations"],
          "properties": {
            "evaluations": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["game_id", "score"],
                "properties": {
                  "game_id": { "type": "integer" },
                  "score": { "type": "number" },
                  "explanation": { "type": "string" },
                  "themes": {
                    "type": "array",
                    "items": { "type": "string" }
                  }
                }
              }
            }
          }
        }
      }|}


let parse_evaluations content =
  try
    let json = Yojson.Safe.from_string content in
    let open Yojson.Safe.Util in
    let items = json |> member "evaluations" |> to_list in
    let evaluations =
      List.filter_map items ~f:(fun item ->
          match member "game_id" item |> to_int_option, member "score" item |> to_float_option with
          | Some game_id, Some score ->
              let explanation = member "explanation" item |> to_string_option in
              let themes =
                match member "themes" item with
                | `Null -> []
                | json_themes ->
                    json_themes
                    |> to_list
                    |> List.filter_map ~f:to_string_option
              in
              Some (game_id, score, explanation, themes)
          | _ -> None)
    in
    Or_error.return evaluations
  with
  | Yojson.Json_error msg | Yojson.Safe.Util.Type_error (msg, _) -> Or_error.error_string msg

let evaluate ~client ~plan ~candidates =
  let limited_candidates = List.take candidates max_candidates in
  if List.is_empty limited_candidates then Or_error.return []
  else
    let effort = effort_for_plan plan in
    let verbosity = verbosity_for_plan plan in
    let system_message =
      Message.
        { role = Role.System
        ; content =
            "You are a chess analyst. Score each candidate game for relevance to the user's question. Provide concise, factual explanations referencing the moves or strategic ideas (e.g., queenside pawn majority)." }
    in
    let user_message =
      Message.
        { role = Role.User
        ; content = build_user_message plan limited_candidates }
    in
    let response_format = Response_format.Json_schema response_schema in
    let* response =
      Agents_gpt5_client.generate
        client
        ~reasoning_effort:effort
        ?verbosity
        ~response_format
        [ system_message; user_message ]
    in
    let* parsed = parse_evaluations response.Response.content in
    let evaluations =
      List.map parsed ~f:(fun (game_id, score, explanation, themes) ->
          { game_id
          ; score = Float.clamp_exn ~min:0.0 ~max:1.0 score
          ; explanation
          ; themes
          ; reasoning_effort = effort
          ; usage = Some response.Response.usage })
    in
    Or_error.return evaluations
