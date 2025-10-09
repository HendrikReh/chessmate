open! Base
open Alcotest

let () =
  run
    "chessmate"
    [ "config", Test_config.suite;
      "embedding-client", Test_embedding_client.suite;
      "retry", Test_retry.suite;
      "openai-common", Test_openai_common.suite;
      "fen", Test_fen.suite;
      "chess-parsing", Test_chess_parsing.suite;
      "query", Test_query.suite;
      "integration", Test_integration.suite;
      "sql-filters", Test_sql_filters.suite;
      "qdrant", Test_qdrant.suite
    ]
