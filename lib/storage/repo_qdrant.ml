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

(* Minimal Qdrant client for upserting and searching chess position vectors. *)

open! Base

module Config = struct
  let collection = "positions"

  let url path =
    match Stdlib.Sys.getenv_opt "QDRANT_URL" with
    | Some base when not (String.is_empty (String.strip base)) -> base ^ path
    | _ -> failwith "QDRANT_URL environment variable must be set"
end

type point = {
  id : string;
  vector : float list;
  payload : Yojson.Safe.t;
}

type scored_point = {
  id : string;
  score : float;
  payload : Yojson.Safe.t option;
}

let point_to_yojson (point : point) =
  `Assoc
    [ "id", `String point.id
    ; "vector", `List (List.map point.vector ~f:(fun v -> `Float v))
    ; "payload", point.payload ]

let headers = Cohttp.Header.init_with "Content-Type" "application/json"

let http_post ~path ~body =
  let uri = Config.url path |> Uri.of_string in
  Cohttp_lwt_unix.Client.post ~headers ~body:(Cohttp_lwt.Body.of_string body) uri

let with_lwt_result f =
  let wrapped =
    Lwt.catch
      (fun () -> f)
      (fun exn -> Lwt.return (Error (Exn.to_string exn)))
  in
  try Lwt_main.run wrapped with
  | exn -> Error (Exn.to_string exn)

let run_request f =
  match with_lwt_result f with
  | Ok value -> Or_error.return value
  | Error msg -> Or_error.error_string msg

let upsert_points_request points =
  let payload =
    `Assoc [ "points", `List (List.map points ~f:point_to_yojson) ]
    |> Yojson.Safe.to_string
  in
  let open Lwt.Syntax in
  let* response, body = http_post ~path:(Printf.sprintf "/collections/%s/points" Config.collection) ~body:payload in
  let status = Cohttp.Response.status response in
  if Cohttp.Code.(code_of_status status = 200) then Lwt.return (Ok ())
  else
    let* body_string = Cohttp_lwt.Body.to_string body in
    Lwt.return (Error (Printf.sprintf "Qdrant upsert failed: %s" body_string))

let upsert_points points = run_request (upsert_points_request points)

let parse_scored_point json =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let score = json |> member "score" |> to_float in
    let payload =
      match member "payload" json with
      | `Null -> None
      | other -> Some other
    in
    Ok { id; score; payload }
  with
  | Type_error (msg, _) | Yojson.Json_error msg -> Error msg

let filter_json_of_clauses = function
  | None -> `Null
  | Some clauses -> `Assoc [ "must", `List clauses ]

let vector_search_request ~vector ~filters ~limit =
  let payload =
    `Assoc
      [ "vector"
        , `Assoc
            [ "name", `String "default"
            ; "vector", `List (List.map vector ~f:(fun v -> `Float v)) ]
      ; "with_payload", `Bool true
      ; "limit", `Int limit
      ; "filter", filter_json_of_clauses filters ]
    |> Yojson.Safe.to_string
  in
  let open Lwt.Syntax in
  let* response, body =
    http_post
      ~path:(Printf.sprintf "/collections/%s/points/search" Config.collection)
      ~body:payload
  in
  let status = Cohttp.Response.status response in
  let* body_string = Cohttp_lwt.Body.to_string body in
  if Cohttp.Code.(code_of_status status = 200) then (
    let open Yojson.Safe.Util in
    try
      let json = Yojson.Safe.from_string body_string in
      let results = json |> member "result" |> to_list in
      let parsed = List.map results ~f:parse_scored_point |> Result.all in
      Lwt.return parsed
    with
    | exn -> Lwt.return (Error (Exn.to_string exn)))
  else
    Lwt.return (Error (Printf.sprintf "Qdrant search failed: %s" body_string))

let vector_search ~vector ~filters ~limit =
  run_request (vector_search_request ~vector ~filters ~limit)
