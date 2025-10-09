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
open Stdio

module Backoff = Retry
module Common = Openai_common

let ( let* ) t f = Or_error.bind t ~f

module Util = Yojson.Safe.Util

let default_endpoint = "https://api.openai.com/v1/responses"
let default_model = "gpt-5"

type http_response = {
  status : int;
  body : string;
}

module Effort = struct
  type t =
    | Minimal
    | Low
    | Medium
    | High

  let to_string = function
    | Minimal -> "minimal"
    | Low -> "low"
    | Medium -> "medium"
    | High -> "high"

  let of_string value =
    match String.lowercase (String.strip value) with
    | "minimal" -> Or_error.return Minimal
    | "low" -> Or_error.return Low
    | "medium" | "" -> Or_error.return Medium
    | "high" -> Or_error.return High
    | other -> Or_error.errorf "Unknown reasoning effort: %s" other
end

module Verbosity = struct
  type t =
    | Low
    | Medium
    | High

  let to_string = function
    | Low -> "low"
    | Medium -> "medium"
    | High -> "high"

  let of_string value =
    match String.lowercase (String.strip value) with
    | "low" -> Or_error.return Low
    | "medium" | "" -> Or_error.return Medium
    | "high" -> Or_error.return High
    | other -> Or_error.errorf "Unknown verbosity: %s" other
end

module Role = struct
  type t =
    | System
    | User
    | Assistant

  let to_string = function
    | System -> "system"
    | User -> "user"
    | Assistant -> "assistant"
end

module Response_format = struct
  type t =
    | Text
    | Json_schema of Yojson.Safe.t

  let to_json = function
    | Text -> `Assoc [ "type", `String "text" ]
    | Json_schema schema ->
        `Assoc
          [ "type", `String "json_schema"
          ; "json_schema", schema ]
end

module Message = struct
  type t = {
    role : Role.t;
    content : string;
  }

  let to_json { role; content } =
    `Assoc
      [ "role", `String (Role.to_string role)
      ; "content"
        , `List
            [ `Assoc
                [ "type", `String "text"
                ; "text", `String content ]
            ]
      ]
end

module Usage = struct
  type t = {
    input_tokens : int option;
    output_tokens : int option;
    reasoning_tokens : int option;
  }

  let empty = { input_tokens = None; output_tokens = None; reasoning_tokens = None }

  let extract_int json key =
    match Util.member key json with
    | `Null -> None
    | value -> (
        match Util.to_int_option value with
        | Some i -> Some i
        | None ->
            (match Util.to_string_option value with
            | Some text -> Int.of_string_opt text
            | None -> None))

  let of_json json =
      try
      let input_tokens = extract_int json "input_tokens" in
      let output_tokens = extract_int json "output_tokens" in
      let reasoning_tokens = extract_int json "reasoning_tokens" in
      { input_tokens; output_tokens; reasoning_tokens }
    with _ -> empty
end

module Response = struct
  type t = {
    content : string;
    usage : Usage.t;
    raw_json : Yojson.Safe.t;
  }
end

type t = {
  api_key : string;
  endpoint : string;
  model : string;
  default_effort : Effort.t;
  default_verbosity : Verbosity.t option;
  retry : Common.retry_config;
}

let non_empty_env name =
  Stdlib.Sys.getenv_opt name
  |> Option.map ~f:String.strip
  |> Option.bind ~f:(fun value -> if String.is_empty value then None else Some value)

let call_api ~endpoint ~api_key ~body =
  let payload_file = Stdlib.Filename.temp_file "chessmate_gpt5_payload" ".json" in
  let response_file = Stdlib.Filename.temp_file "chessmate_gpt5_response" ".json" in
  Exn.protect
    ~f:(fun () ->
        Out_channel.write_all payload_file ~data:body;
        let command =
          Printf.sprintf
            "curl -sS -X POST %s -H %s -H %s --data-binary @%s -o %s -w '%%{http_code}'"
            (Stdlib.Filename.quote endpoint)
            (Stdlib.Filename.quote ("Authorization: Bearer " ^ api_key))
            (Stdlib.Filename.quote "Content-Type: application/json")
            (Stdlib.Filename.quote payload_file)
            (Stdlib.Filename.quote response_file)
        in
        let ic, oc, ec = Unix.open_process_full command (Unix.environment ()) in
        Out_channel.close oc;
        let status_text = In_channel.input_all ic |> String.strip in
        let stderr = In_channel.input_all ec |> String.strip in
        match Unix.close_process_full (ic, oc, ec) with
        | Unix.WEXITED 0 -> (
            match Int.of_string_opt status_text with
            | None -> Or_error.errorf "curl returned invalid status code: %s" status_text
            | Some status ->
                let body = In_channel.read_all response_file in
                Or_error.return { status; body })
        | Unix.WEXITED code ->
            Or_error.errorf "curl exited with code %d: %s" code stderr
        | Unix.WSIGNALED signal -> Or_error.errorf "curl terminated by signal %d" signal
        | Unix.WSTOPPED signal -> Or_error.errorf "curl stopped by signal %d" signal)
    ~finally:(fun () ->
      (try Stdlib.Sys.remove payload_file with _ -> ());
      (try Stdlib.Sys.remove response_file with _ -> ()))

let ensure_non_empty name value =
  if String.is_empty (String.strip value) then
    Or_error.errorf "%s cannot be empty" name
  else
    Or_error.return value

let create
    ~api_key
    ?(endpoint = default_endpoint)
    ?(model = default_model)
    ?(default_effort = Effort.Medium)
    ?default_verbosity
    ()
  =
  let* api_key = ensure_non_empty "api_key" api_key in
  let* endpoint = ensure_non_empty "endpoint" endpoint in
  let* model = ensure_non_empty "model" model in
  let retry = Common.load_retry_config () in
  Or_error.return { api_key; endpoint; model; default_effort; default_verbosity; retry }

let create_from_env () =
  let* api_key =
    match non_empty_env "AGENT_API_KEY" with
    | Some key -> Or_error.return key
    | None -> Or_error.error_string "AGENT_API_KEY not set"
  in
  let endpoint = Option.value (non_empty_env "AGENT_ENDPOINT") ~default:default_endpoint in
  let model = Option.value (non_empty_env "AGENT_MODEL") ~default:default_model in
  let* default_effort =
    match non_empty_env "AGENT_REASONING_EFFORT" with
    | None -> Or_error.return Effort.Medium
    | Some value -> Effort.of_string value
  in
  let* default_verbosity =
    match non_empty_env "AGENT_VERBOSITY" with
    | None -> Or_error.return None
    | Some value -> Verbosity.of_string value |> Or_error.map ~f:Option.some
  in
  create ~api_key ~endpoint ~model ~default_effort ?default_verbosity ()

let effort_to_use t override = Option.value override ~default:t.default_effort
let verbosity_to_use t override = Option.first_some override t.default_verbosity

let response_field name json =
  match Util.member name json with
  | `Null -> None
  | value -> Some value

let extract_text_from_output output =
  let rec loop items =
    match items with
    | [] -> None
    | item :: rest ->
        let content = Util.member "content" item in
        (match content with
        | `List entries -> (
            let texts =
              entries
              |> List.filter_map ~f:(fun entry ->
                     match Util.member "type" entry with
                     | `String "text" -> Util.member "text" entry |> Util.to_string_option
                     | _ -> None)
            in
            match texts with
            | [] -> loop rest
            | _ -> Some (String.concat ~sep:"\n" texts))
        | _ -> loop rest)
  in
  match output with
  | `List items -> loop items
  | _ -> None

let extract_text json =
  match response_field "output" json with
  | Some output -> (
      match extract_text_from_output output with
      | Some text -> Some text
      | None -> None)
  | None -> (
      match response_field "choices" json with
      | Some (`List (choice :: _)) -> (
          match Util.member "message" choice with
          | `Assoc _ as message -> Util.member "content" message |> Util.to_string_option
          | _ -> Util.member "text" choice |> Util.to_string_option)
      | _ -> None)

let reasoning_field effort =
  `Assoc [ "reasoning", `Assoc [ "effort", `String (Effort.to_string effort) ] ]

let verbosity_field verbosity =
  match verbosity with
  | None -> []
  | Some level -> [ "response", `Assoc [ "verbosity", `String (Verbosity.to_string level) ] ]

let response_format_field = function
  | None -> []
  | Some format -> [ "response_format", Response_format.to_json format ]

let max_tokens_field = function
  | None -> []
  | Some value when value > 0 -> [ "max_output_tokens", `Int value ]
  | Some _ -> []

let build_payload ~model ~messages ~effort ~verbosity ~max_output_tokens ~response_format =
  let base_fields =
    [ "model", `String model
    ; "input", `List (List.map messages ~f:Message.to_json) ]
  in
  let all_fields =
    base_fields
    @ (match reasoning_field effort with `Assoc assoc -> assoc | _ -> [])
    @ verbosity_field verbosity
    @ response_format_field response_format
    @ max_tokens_field max_output_tokens
  in
  `Assoc all_fields |> Yojson.Safe.to_string

let generate
    t
    ?reasoning_effort
    ?verbosity
    ?max_output_tokens
    ?response_format
    (messages : Message.t list)
  =
  if List.is_empty messages then Or_error.error_string "Agent prompt cannot be empty"
  else
    let effort = effort_to_use t reasoning_effort in
    let verbosity = verbosity_to_use t verbosity in
    let body =
      build_payload
        ~model:t.model
        ~messages
        ~effort
        ~verbosity
        ~max_output_tokens
        ~response_format
    in
    let attempt ~attempt:_ =
      match call_api ~endpoint:t.endpoint ~api_key:t.api_key ~body with
      | Error err -> Backoff.Retry (Error.tag err ~tag:"agent request failed")
      | Ok { status; _ } when Common.should_retry_status status ->
          let err = Error.of_string (Printf.sprintf "GPT-5 transient status %d" status) in
          Backoff.Retry err
      | Ok { status; body } when status < 200 || status >= 300 ->
          let message =
            Printf.sprintf "GPT-5 request failed with status %d: %s" status (Common.truncate_body body)
          in
          Backoff.Resolved (Or_error.error_string message)
      | Ok { status = _; body } -> (
          match Yojson.Safe.from_string body with
          | exception exn ->
              Backoff.Retry (Error.of_exn exn)
          | json -> (
              match Util.member "error" json with
              | `Null ->
                  let content_result =
                    match extract_text json with
                    | Some text -> Or_error.return text
                    | None -> Or_error.error_string "GPT-5 response did not contain any text output"
                  in
                  (match content_result with
                  | Error err -> Backoff.Resolved (Error err)
                  | Ok content ->
                      let usage =
                        match response_field "usage" json with
                        | Some usage_json -> Usage.of_json usage_json
                        | None -> Usage.empty
                      in
                      Backoff.Resolved (Or_error.return Response.{ content; usage; raw_json = json }))
              | error_json ->
                  let message =
                    Util.member "message" error_json |> Util.to_string_option |> Option.value ~default:"unknown error"
                  in
                  let err = Error.of_string (Printf.sprintf "GPT-5 error: %s" message) in
                  if Common.should_retry_error_json error_json then Backoff.Retry err
                  else Backoff.Resolved (Error err)))
    in
    Backoff.with_backoff
      ~max_attempts:t.retry.max_attempts
      ~initial_delay:t.retry.initial_delay
      ~multiplier:t.retry.multiplier
      ~jitter:t.retry.jitter
      ~on_retry:(fun ~attempt ~delay err ->
        Common.log_retry
          ~label:"openai-agent"
          ~attempt
          ~max_attempts:t.retry.max_attempts
          ~delay
          err)
      ~f:attempt
      ()
