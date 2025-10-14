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
