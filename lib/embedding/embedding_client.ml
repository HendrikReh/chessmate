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

module Util = Yojson.Safe.Util

type http_response = {
  status : int;
  body : string;
}

type t = {
  api_key : string;
  endpoint : string;
  model : string;
  retry : Common.retry_config;
}

let default_model = "text-embedding-3-small"

let create ~api_key ~endpoint =
  if String.is_empty (String.strip api_key) then Or_error.error_string "OPENAI_API_KEY missing"
  else if String.is_empty (String.strip endpoint) then Or_error.error_string "OpenAI endpoint missing"
  else
    let retry = Common.load_retry_config () in
    Or_error.return { api_key; endpoint; model = default_model; retry }

let call_curl ~endpoint ~api_key ~body =
  let payload_file = Stdlib.Filename.temp_file "chessmate_embedding" ".json" in
  let response_file = Stdlib.Filename.temp_file "chessmate_embedding_response" ".json" in
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
        | Unix.WEXITED code -> Or_error.errorf "curl exited with code %d: %s" code stderr
        | Unix.WSIGNALED signal -> Or_error.errorf "curl terminated by signal %d" signal
        | Unix.WSTOPPED signal -> Or_error.errorf "curl stopped by signal %d" signal)
    ~finally:(fun () ->
      (try Stdlib.Sys.remove payload_file with _ -> ());
      (try Stdlib.Sys.remove response_file with _ -> ()))

let parse_embeddings json =
  try
    let data = Util.member "data" json |> Util.to_list in
    data
    |> List.map ~f:(fun item ->
           let embedding = Util.member "embedding" item |> Util.to_list in
           embedding
           |> List.map ~f:Util.to_float
           |> Array.of_list)
    |> Or_error.return
  with exn -> Or_error.of_exn exn

let embed_fens t fens =
  if List.is_empty fens then Or_error.return []
  else
    let payload =
      `Assoc
        [ "model", `String t.model
        ; "input", `List (List.map fens ~f:(fun fen -> `String fen))
        ]
      |> Yojson.Safe.to_string
    in
    let attempt ~attempt:_ =
      match call_curl ~endpoint:t.endpoint ~api_key:t.api_key ~body:payload with
      | Error err ->
          Backoff.Retry (Error.tag err ~tag:"embedding request failed")
      | Ok { status; _ } when Common.should_retry_status status ->
          let err = Error.of_string (Printf.sprintf "OpenAI transient status %d" status) in
          Backoff.Retry err
      | Ok { status; body } when status < 200 || status >= 300 ->
          let message =
            Printf.sprintf "OpenAI request failed with status %d: %s" status (Common.truncate_body body)
          in
          Backoff.Resolved (Or_error.error_string message)
      | Ok { status = _; body } -> (
          match Yojson.Safe.from_string body with
          | exception exn -> Backoff.Retry (Error.of_exn exn)
          | json -> (
              match Util.member "error" json with
              | `Null -> Backoff.Resolved (parse_embeddings json)
              | err_json ->
                  let message =
                    Util.member "message" err_json |> Util.to_string_option |> Option.value ~default:"unknown error"
                  in
                  let err =
                    Error.of_string (Printf.sprintf "OpenAI error: %s" message)
                  in
                  if Common.should_retry_error_json err_json then Backoff.Retry err
                  else Backoff.Resolved (Error err)))
    in
    Backoff.with_backoff
      ~max_attempts:t.retry.max_attempts
      ~initial_delay:t.retry.initial_delay
      ~multiplier:t.retry.multiplier
      ~jitter:t.retry.jitter
      ~on_retry:(fun ~attempt ~delay err ->
        Common.log_retry
          ~label:"openai-embedding"
          ~attempt
          ~max_attempts:t.retry.max_attempts
          ~delay
          err)
      ~f:attempt
      ()
