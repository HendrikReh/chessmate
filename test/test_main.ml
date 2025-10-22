open! Base
open Alcotest

let () =
  run "chessmate"
    [
      ("health", Test_health.suite);
      ("query", Test_query.suite);
      ("temp_file_guard", Test_temp_file_guard.suite);
      ("worker_health_endpoint", Test_worker_health_endpoint.suite);
      ("rate_limiter_http", Test_rate_limiter_http.suite);
    ]
