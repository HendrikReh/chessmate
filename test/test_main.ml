open! Base
open Alcotest

let () =
  run
    "chessmate"
    [ "config", Test_config.suite;
      "retry", Test_retry.suite;
      "openai-common", Test_openai_common.suite;
      "fen", Test_fen.suite;
      "chess-parsing", Test_chess_parsing.suite;
      "query", Test_query.suite
    ]
