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

let chunk_list = Chessmate.Embedding_client.Private.chunk_list
let enforce_char_limit = Chessmate.Embedding_client.Private.enforce_char_limit
let total_chars = Chessmate.Embedding_client.Private.total_chars

let test_chunk_list () =
  let data = List.init 10 ~f:Int.to_string in
  let chunks = chunk_list data ~chunk_size:3 in
  check int "chunk count" 4 (List.length chunks);
  check
    (list (list string))
    "chunk structure"
    [ [ "0"; "1"; "2" ]; [ "3"; "4"; "5" ]; [ "6"; "7"; "8" ]; [ "9" ] ]
    chunks

let test_enforce_char_limit () =
  let chunk = [ String.make 10 'a'; String.make 20 'b'; String.make 15 'c' ] in
  let max_chars = 25 in
  let chunks = enforce_char_limit chunk ~max_chars in
  check int "split into three" 3 (List.length chunks);
  check bool "each chunk under limit" true
    (List.for_all chunks ~f:(fun subchunk -> total_chars subchunk <= max_chars))

let suite =
  [
    test_case "chunk list splits correctly" `Quick test_chunk_list;
    test_case "char limit enforces bound" `Quick test_enforce_char_limit;
  ]
