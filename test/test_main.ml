open! Base
open Alcotest

let () =
  run "chessmate" [ ("health", Test_health.suite); ("query", Test_query.suite) ]
