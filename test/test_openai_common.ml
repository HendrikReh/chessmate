open! Base
open Alcotest
open Chessmate

let test_should_retry_status () =
  check bool "429 retryable" true (Openai_common.should_retry_status 429);
  check bool "200 not retryable" false (Openai_common.should_retry_status 200);
  check bool "503 retryable" true (Openai_common.should_retry_status 503)

let test_should_retry_error_json () =
  let rate_limit =
    `Assoc
      [ "type", `String "rate_limit_error"
      ; "message", `String "Rate limit exceeded" ]
  in
  let invalid =
    `Assoc
      [ "type", `String "invalid_request_error"
      ; "message", `String "Invalid parameters" ]
  in
  check bool "rate limit" true (Openai_common.should_retry_error_json rate_limit);
  check bool "invalid request" false (Openai_common.should_retry_error_json invalid)

let suite =
  [ test_case "retry status classification" `Quick test_should_retry_status
  ; test_case "retry error classification" `Quick test_should_retry_error_json
  ]
