open! Base
open Alcotest
open Chessmate

let secret = "sk-test-1234567890abcdef"

let test_redacts_openai_key () =
  let input = Printf.sprintf "OpenAI failed with key=%s" secret in
  let sanitized = Sanitizer.sanitize_string input in
  check bool "redacted" false (String.is_substring sanitized ~substring:secret);
  check bool "contains redacted token" true
    (String.is_substring sanitized ~substring:"[redacted]")

let test_redacts_database_url () =
  let input = "error connecting to postgres://user:pass@localhost/db" in
  let sanitized = Sanitizer.sanitize_string input in
  check bool "dbname hidden" false
    (String.is_substring sanitized ~substring:"postgres://user:pass");
  check bool "redaction marker" true
    (String.is_substring sanitized ~substring:"[redacted]")

let suite =
  [
    ("redacts api key", `Quick, test_redacts_openai_key);
    ("redacts database url", `Quick, test_redacts_database_url);
  ]
