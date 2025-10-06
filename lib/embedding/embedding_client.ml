open! Base
open Stdio

let ( let* ) t f = Or_error.bind t ~f

module Util = Yojson.Safe.Util

type t = {
  api_key : string;
  endpoint : string;
  model : string;
}

let default_model = "text-embedding-3-small"

let create ~api_key ~endpoint =
  if String.is_empty (String.strip api_key) then Or_error.error_string "OPENAI_API_KEY missing"
  else if String.is_empty (String.strip endpoint) then Or_error.error_string "OpenAI endpoint missing"
  else Or_error.return { api_key; endpoint; model = default_model }

let call_curl ~endpoint ~api_key ~body =
  let payload_file = Stdlib.Filename.temp_file "chessmate_embedding" ".json" in
  Exn.protect
    ~f:(fun () ->
        Out_channel.write_all payload_file ~data:body;
        let command =
          Printf.sprintf
            "curl -sS -X POST %s -H %s -H %s --data-binary @%s"
            (Stdlib.Filename.quote endpoint)
            (Stdlib.Filename.quote ("Authorization: Bearer " ^ api_key))
            (Stdlib.Filename.quote "Content-Type: application/json")
            (Stdlib.Filename.quote payload_file)
        in
        let ic, oc, ec = Unix.open_process_full command (Unix.environment ()) in
        Out_channel.close oc;
        let stdout = In_channel.input_all ic in
        let stderr = In_channel.input_all ec in
        match Unix.close_process_full (ic, oc, ec) with
        | Unix.WEXITED 0 -> Or_error.return stdout
        | Unix.WEXITED code -> Or_error.errorf "curl exited with code %d: %s" code (String.strip stderr)
        | Unix.WSIGNALED signal -> Or_error.errorf "curl terminated by signal %d" signal
        | Unix.WSTOPPED signal -> Or_error.errorf "curl stopped by signal %d" signal)
    ~finally:(fun () -> try Stdlib.Sys.remove payload_file with _ -> ())

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
    let* response = call_curl ~endpoint:t.endpoint ~api_key:t.api_key ~body:payload in
    match Yojson.Safe.from_string response with
    | json -> (
        match Util.member "error" json with
        | `Null -> parse_embeddings json
        | err_json ->
            let message = Util.member "message" err_json |> Util.to_string_option |> Option.value ~default:"unknown error" in
            Or_error.errorf "OpenAI error: %s" message)
    | exception exn -> Or_error.of_exn exn
