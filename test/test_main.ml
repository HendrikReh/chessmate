open! Base
open Alcotest

let () =
  run
    "chessmate"
    [ "chess-parsing", Test_chess_parsing.suite;
      "query", Test_query.suite
    ]
