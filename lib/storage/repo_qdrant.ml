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

(** Minimal Qdrant HTTP client used to upsert embedding vectors and fetch scored
    points for hybrid search. *)

open! Base

module Config = struct
  let collection = "positions"

  let url path =
    match Stdlib.Sys.getenv_opt "QDRANT_URL" with
    | Some base when not (String.is_empty (String.strip base)) -> base ^ path
    | _ -> failwith "QDRANT_URL environment variable must be set"
end

type point = { id : string; vector : float list; payload : Yojson.Safe.t }

type scored_point = {
  id : string;
  score : float;
  payload : Yojson.Safe.t option;
}

type test_hooks = {
  upsert : point list -> unit Or_error.t;
  search :
    vector:float list ->
    filters:Yojson.Safe.t list option ->
    limit:int ->
    scored_point list Or_error.t;
}

let test_hooks_ref : test_hooks option ref = ref None

let with_test_hooks hooks f =
  let previous = !test_hooks_ref in
  test_hooks_ref := Some hooks;
  Exn.protect ~f ~finally:(fun () -> test_hooks_ref := previous)

let point_to_yojson (point : point) =
  `Assoc
    [
      ("id", `String point.id);
      ("vector", `List (List.map point.vector ~f:(fun v -> `Float v)));
      ("payload", point.payload);
    ]

let headers = Cohttp.Header.init_with "Content-Type" "application/json"

let http_post ~path ~body =
  let uri = Config.url path |> Uri.of_string in
  Cohttp_lwt_unix.Client.post ~headers
    ~body:(Cohttp_lwt.Body.of_string body)
    uri

let http_get ~path =
  let uri = Config.url path |> Uri.of_string in
  Cohttp_lwt_unix.Client.get uri

let http_put ~path ~body =
  let uri = Config.url path |> Uri.of_string in
  Cohttp_lwt_unix.Client.put ~headers ~body:(Cohttp_lwt.Body.of_string body) uri

let with_lwt_result f =
  let wrapped =
    Lwt.catch (fun () -> f) (fun exn -> Lwt.return (Error (Exn.to_string exn)))
  in
  try Lwt_main.run wrapped with exn -> Error (Exn.to_string exn)

let run_request f =
  match with_lwt_result f with
  | Ok value -> Or_error.return value
  | Error msg -> Or_error.error_string msg

let upsert_points_request points =
  let payload =
    `Assoc [ ("points", `List (List.map points ~f:point_to_yojson)) ]
    |> Yojson.Safe.to_string
  in
  let open Lwt.Syntax in
  let* response, body =
    http_post
      ~path:(Printf.sprintf "/collections/%s/points" Config.collection)
      ~body:payload
  in
  let status = Cohttp.Response.status response in
  if Cohttp.Code.(code_of_status status = 200) then Lwt.return (Ok ())
  else
    let* body_string = Cohttp_lwt.Body.to_string body in
    Lwt.return (Error (Printf.sprintf "Qdrant upsert failed: %s" body_string))

let upsert_points points =
  match !test_hooks_ref with
  | Some hooks -> hooks.upsert points
  | None -> run_request (upsert_points_request points)

let parse_scored_point json =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let score = json |> member "score" |> to_float in
    let payload =
      match member "payload" json with `Null -> None | other -> Some other
    in
    Ok { id; score; payload }
  with Type_error (msg, _) | Yojson.Json_error msg -> Error msg

let filter_json_of_clauses = function
  | None -> `Null
  | Some clauses -> `Assoc [ ("must", `List clauses) ]

let vector_search_request ~vector ~filters ~limit =
  let payload =
    `Assoc
      [
        ( "vector",
          `Assoc
            [
              ("name", `String "default");
              ("vector", `List (List.map vector ~f:(fun v -> `Float v)));
            ] );
        ("with_payload", `Bool true);
        ("limit", `Int limit);
        ("filter", filter_json_of_clauses filters);
      ]
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
  if Cohttp.Code.(code_of_status status = 200) then
    let open Yojson.Safe.Util in
    try
      let json = Yojson.Safe.from_string body_string in
      let results = json |> member "result" |> to_list in
      let parsed = List.map results ~f:parse_scored_point |> Result.all in
      Lwt.return parsed
    with exn -> Lwt.return (Error (Exn.to_string exn))
  else
    Lwt.return (Error (Printf.sprintf "Qdrant search failed: %s" body_string))

let vector_search ~vector ~filters ~limit =
  match !test_hooks_ref with
  | Some hooks -> hooks.search ~vector ~filters ~limit
  | None -> run_request (vector_search_request ~vector ~filters ~limit)

let ensure_collection_request ~name ~vector_size ~distance =
  let open Lwt.Syntax in
  let path = Printf.sprintf "/collections/%s" name in
  let* response, body = http_get ~path in
  let status = Cohttp.Response.status response in
  let code = Cohttp.Code.code_of_status status in
  if Int.equal code 200 then Lwt.return (Ok ())
  else
    let* body_string = Cohttp_lwt.Body.to_string body in
    if Int.equal code 404 then
      let payload =
        `Assoc
          [
            ( "vectors",
              `Assoc
                [ ("size", `Int vector_size); ("distance", `String distance) ]
            );
            ( "payload_schema",
              `Assoc
                [
                  ("game_id", `Assoc [ ("type", `String "integer") ]);
                  ("fen", `Assoc [ ("type", `String "keyword") ]);
                  ("white", `Assoc [ ("type", `String "keyword") ]);
                  ("black", `Assoc [ ("type", `String "keyword") ]);
                  ("opening_slug", `Assoc [ ("type", `String "keyword") ]);
                ] );
          ]
        |> Yojson.Safe.to_string
      in
      let* response, body = http_put ~path ~body:payload in
      let status = Cohttp.Response.status response in
      let code = Cohttp.Code.code_of_status status in
      if code = 200 || code = 201 || code = 202 then Lwt.return (Ok ())
      else
        let* body_string = Cohttp_lwt.Body.to_string body in
        Lwt.return
          (Error (Printf.sprintf "Failed to create collection: %s" body_string))
    else
      Lwt.return
        (Error (Printf.sprintf "Unexpected status %d: %s" code body_string))

let ensure_collection ~name ~vector_size ~distance =
  match !test_hooks_ref with
  | Some _ -> Or_error.return ()
  | None -> run_request (ensure_collection_request ~name ~vector_size ~distance)
