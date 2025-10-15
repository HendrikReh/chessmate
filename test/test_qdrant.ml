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
open Alcotest
open Chessmate

let test_upsert_and_search () =
  let captured_points = ref None in
  let hooks =
    {
      Repo_qdrant.upsert =
        (fun points ->
          captured_points := Some points;
          Or_error.return ());
      search =
        (fun ~vector:_ ~filters:_ ~limit:_ ->
          match !captured_points with
          | Some (point :: _) ->
              let result =
                {
                  Repo_qdrant.id = point.id;
                  score = 0.42;
                  payload = Some point.payload;
                }
              in
              Or_error.return [ result ]
          | _ -> Or_error.return []);
      create_snapshot =
        (fun ~collection:_ ~snapshot_name:_ ->
          Or_error.error_string "create_snapshot hook not set");
      list_snapshots =
        (fun ~collection:_ ->
          Or_error.error_string "list_snapshots hook not set");
      restore_snapshot =
        (fun ~collection:_ ~location:_ ->
          Or_error.error_string "restore_snapshot hook not set");
    }
  in
  let test () =
    let point =
      {
        Repo_qdrant.id = "vector-123";
        vector = [ 0.1; 0.2; 0.3 ];
        payload = `Assoc [ ("game_id", `Int 42) ];
      }
    in
    (match Repo_qdrant.upsert_points [ point ] with
    | Ok () -> ()
    | Error err ->
        failf "expected upsert success but got %s" (Error.to_string_hum err));
    match
      Repo_qdrant.vector_search ~vector:[ 0.01; 0.02; 0.03 ] ~filters:None
        ~limit:1
    with
    | Ok [ hit ] -> (
        check string "vector id" "vector-123" hit.Repo_qdrant.id;
        (match hit.payload with
        | Some payload ->
            let game_id =
              Yojson.Safe.Util.(payload |> member "game_id" |> to_int)
            in
            check int "payload game_id" 42 game_id
        | None -> fail "search payload missing");
        match !captured_points with
        | Some (_ :: _) -> ()
        | _ -> fail "upsert hook did not capture point")
    | Ok [] -> fail "expected search result"
    | Ok _ -> fail "unexpected multiple search results"
    | Error err ->
        failf "expected search success but got %s" (Error.to_string_hum err)
  in
  Repo_qdrant.with_test_hooks hooks test

let suite = [ ("upsert vector then search", `Quick, test_upsert_and_search) ]
