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

(** Implement the `chessmate query` CLI command by posting questions to the HTTP
    API and formatting JSON responses for the terminal. *)

open! Base

let build_uri () =
  (* CLI users configure CHESSMATE_API_URL; default is http://localhost:8080. We strip
     trailing slashes so we can safely append /query. *)
  let base = Cli_common.api_base_url () in
  let normalised = String.rstrip base ~drop:(Char.equal '/') in
  Uri.of_string (normalised ^ "/query")

let request_body ~question ?limit ?offset () =
  let fields = ref [ ("question", `String question) ] in
  (match limit with
  | Some value -> fields := ("limit", `Int value) :: !fields
  | None -> ());
  (match offset with
  | Some value -> fields := ("offset", `Int value) :: !fields
  | None -> ());
  `Assoc (List.rev !fields) |> Yojson.Safe.to_string

let perform_request uri body =
  let open Lwt.Syntax in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  let* response, body_stream =
    Cohttp_lwt_unix.Client.post ~headers
      ~body:(Cohttp_lwt.Body.of_string body)
      uri
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
    let offset = json |> member "offset" |> to_int in
    let total = json |> member "total" |> to_int in
    let has_more = json |> member "has_more" |> to_bool in
    let has_more_str = if has_more then "yes" else "no" in
    let agent_status =
      match json |> member "agent_status" |> to_string_option with
      | Some status when not (String.is_empty (String.strip status)) -> status
      | _ -> "unknown"
    in
    let filters =
      plan |> member "filters" |> to_list
      |> List.map ~f:(fun filter ->
             let field = filter |> member "field" |> to_string in
             let value = filter |> member "value" |> to_string in
             (field, value))
    in
    let rating = plan |> member "rating" in
    let rating_line field =
      match rating |> member field with
      | `Null -> None
      | json_value -> (
          match json_value with
          | `Int value -> Some (Printf.sprintf "%s=%d" field value)
          | `Float value -> Some (Printf.sprintf "%s=%.2f" field value)
          | _ ->
              Some
                (Printf.sprintf "%s=%s" field
                   (Yojson.Safe.to_string json_value)))
    in
    let rating_bits =
      List.filter_map
        [ "white_min"; "black_min"; "max_rating_delta" ]
        ~f:rating_line
    in
    let results = json |> member "results" |> to_list in
    let result_lines =
      List.mapi results ~f:(fun index item ->
          let game_id = item |> member "game_id" |> to_int in
          let white = item |> member "white" |> to_string in
          let black = item |> member "black" |> to_string in
          let score = item |> member "score" |> to_float in
          let opening =
            match member "opening_name" item |> to_string_option with
            | Some name when not (String.is_empty (String.strip name)) -> name
            | _ ->
                Option.value
                  (member "opening_slug" item |> to_string_option)
                  ~default:"unknown_opening"
          in
          let synopsis = item |> member "synopsis" |> to_string in
          let agent_score = member "agent_score" item |> to_float_option in
          let agent_explanation =
            member "agent_explanation" item |> to_string_option
          in
          let agent_themes =
            member "agent_themes" item |> function
            | `Null -> []
            | json -> json |> to_list |> List.filter_map ~f:to_string_option
          in
          let agent_line =
            match agent_score with
            | Some agent when Float.(agent > 0.) ->
                let theme_suffix =
                  match agent_themes with
                  | [] -> ""
                  | themes ->
                      Printf.sprintf " (themes: %s)"
                        (String.concat ~sep:", " themes)
                in
                let explanation_suffix =
                  match agent_explanation with
                  | Some explanation -> Printf.sprintf " — %s" explanation
                  | None -> ""
                in
                Printf.sprintf "Agent score %.2f%s%s" agent theme_suffix
                  explanation_suffix
            | _ -> ""
          in
          let details =
            if String.is_empty agent_line then synopsis
            else synopsis ^ "\n       " ^ agent_line
          in
          Printf.sprintf "%d. #%d %s vs %s [%s] score %.2f\n       %s"
            (index + 1) game_id white black opening score details)
    in
    let filters_line =
      if List.is_empty filters then "No structured filters detected"
      else
        filters
        |> List.map ~f:(fun (field, value) ->
               Printf.sprintf "%s=%s" field value)
        |> String.concat ~sep:", "
    in
    let summary_bits =
      [
        Printf.sprintf "Summary: %s" summary;
        Printf.sprintf "Offset: %d" offset;
        Printf.sprintf "Limit: %d" limit;
        Printf.sprintf "Total matches: %d" total;
        Printf.sprintf "Has more: %s" has_more_str;
        Printf.sprintf "Agent status: %s" agent_status;
        Printf.sprintf "Filters: %s" filters_line;
        (match rating_bits with
        | [] -> "Ratings: none"
        | bits -> Printf.sprintf "Ratings: %s" (String.concat ~sep:", " bits));
      ]
    in
    let results_block =
      if List.is_empty result_lines then [ "No matching games found" ]
      else "Results:" :: result_lines
    in
    Or_error.return (String.concat ~sep:"\n" (summary_bits @ results_block))
  with Yojson.Json_error msg | Type_error (msg, _) ->
    Or_error.errorf "Malformed response from query API: %s" msg

let parse_response status body =
  if Int.equal status 200 then parse_success body
  else
    let open Yojson.Safe.Util in
    match Yojson.Safe.from_string body with
    | (exception Yojson.Json_error _) | (exception Type_error (_, _)) ->
        Or_error.errorf "query API responded with status %d and unreadable body"
          status
    | json -> (
        match json |> member "error" |> to_string_option with
        | Some message -> Or_error.error_string message
        | None -> Or_error.errorf "query API responded with status %d" status)

let run ?(as_json = false) ?limit ?offset query =
  if String.is_empty (String.strip query) then
    Or_error.error_string "query cannot be empty"
  else
    let uri = build_uri () in
    (* Run the Lwt promise to completion; capture the HTTP status and response body. *)
    match
      Lwt_main.run
        (perform_request uri (request_body ~question:query ?limit ?offset ()))
    with
    | status, body ->
        if as_json then
          if Int.equal status 200 then (
            Stdio.printf "%s\n" body;
            Or_error.return ())
          else Or_error.map (parse_response status body) ~f:(fun _ -> ())
        else
          Result.map (parse_response status body) ~f:(fun output ->
              Stdio.printf "%s\n" output;
              ())
    | exception exn -> Or_error.of_exn exn
