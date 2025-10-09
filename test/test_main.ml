open! Base
open Alcotest

let () =
  run
    "chessmate"
    [ "fen", Test_fen.suite;
      "chess-parsing", Test_chess_parsing.suite;
      "query", Test_query.suite
    ]
