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

let build_uri () =
  let base = Cli_common.api_base_url () in
  let normalised = String.rstrip base ~drop:(Char.equal '/') in
  Uri.of_string (normalised ^ "/query")

let request_body query =
  `Assoc [ "question", `String query ] |> Yojson.Safe.to_string

let perform_request uri body =
  let open Lwt.Syntax in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  let* response, body_stream =
    Cohttp_lwt_unix.Client.post ~headers ~body:(Cohttp_lwt.Body.of_string body) uri
  in
  let* body_string = Cohttp_lwt.Body.to_string body_stream in
  let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
  Lwt.return (status, body_string)

let parse_success body =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body in
    let summary = json |> member "summary" |> to_string in
    let plan = json |> member "plan" in
    let limit = plan |> member "limit" |> to_int in
    let filters =
      plan
      |> member "filters"
      |> to_list
      |> List.map ~f:(fun filter ->
             let field = filter |> member "field" |> to_string in
             let value = filter |> member "value" |> to_string in
             field, value)
    in
    let rating = plan |> member "rating" in
    let rating_line field =
      match rating |> member field with
      | `Null -> None
      | json_value -> (
          match json_value with
          | `Int value -> Some (Printf.sprintf "%s=%d" field value)
          | `Float value -> Some (Printf.sprintf "%s=%.2f" field value)
          | _ -> Some (Printf.sprintf "%s=%s" field (Yojson.Safe.to_string json_value)))
    in
    let rating_bits = List.filter_map [ "white_min"; "black_min"; "max_rating_delta" ] ~f:rating_line in
    let results = json |> member "results" |> to_list in
    let result_lines =
      List.mapi results ~f:(fun index item ->
          let game_id = item |> member "game_id" |> to_int in
          let white = item |> member "white" |> to_string in
          let black = item |> member "black" |> to_string in
          let score = item |> member "score" |> to_float in
          let opening = item |> member "opening" |> to_string in
          let synopsis = item |> member "synopsis" |> to_string in
          Printf.sprintf
            "%d. #%d %s vs %s [%s] score %.2f\n       %s"
            (index + 1)
            game_id
            white
            black
            opening
            score
            synopsis)
    in
    let filters_line =
      if List.is_empty filters then "No structured filters detected"
      else
        filters
        |> List.map ~f:(fun (field, value) -> Printf.sprintf "%s=%s" field value)
        |> String.concat ~sep:", "
    in
    let summary_bits =
      [ Printf.sprintf "Summary: %s" summary
      ; Printf.sprintf "Limit: %d" limit
      ; Printf.sprintf "Filters: %s" filters_line
      ; (match rating_bits with
        | [] -> "Ratings: none"
        | bits -> Printf.sprintf "Ratings: %s" (String.concat ~sep:", " bits)) ]
    in
    let results_block =
      if List.is_empty result_lines then [ "No matching games found" ] else "Results:" :: result_lines
    in
    Or_error.return (String.concat ~sep:"\n" (summary_bits @ results_block))
  with
  | Yojson.Json_error msg | Type_error (msg, _) -> Or_error.error_string msg

let parse_response status body =
  if Int.equal status 200 then parse_success body
  else
    let open Yojson.Safe.Util in
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ | exception Type_error (_, _) -> Or_error.errorf "query API responded with status %d" status
    | json -> (
        match json |> member "error" |> to_string_option with
        | Some message -> Or_error.error_string message
        | None -> Or_error.errorf "query API responded with status %d" status)

let run query =
  if String.is_empty (String.strip query) then Or_error.error_string "query cannot be empty"
  else
    let uri = build_uri () in
    match Lwt_main.run (perform_request uri (request_body query)) with
    | status, body ->
        Result.map (parse_response status body) ~f:(fun output ->
            Stdio.printf "%s\n" output;
            ())
    | exception exn -> Or_error.of_exn exn
