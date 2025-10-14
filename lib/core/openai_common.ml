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
open Stdio
module Util = Yojson.Safe.Util

type retry_config = {
  max_attempts : int;
  initial_delay : float;
  multiplier : float;
  jitter : float;
}

let default_retry_config =
  { max_attempts = 5; initial_delay = 0.2; multiplier = 2.0; jitter = 0.2 }

let load_retry_config () =
  let trimmed_env name =
    Stdlib.Sys.getenv_opt name |> Option.map ~f:String.strip
    |> Option.filter ~f:(fun value -> not (String.is_empty value))
  in
  let parse_positive_int name raw =
    match Int.of_string_opt raw with
    | Some value when value > 0 -> Or_error.return value
    | _ ->
        Or_error.errorf
          "Configuration error: %s=%s is invalid (expected a positive integer)"
          name raw
  in
  let parse_positive_float_ms name raw =
    match Float.of_string raw with
    | value when Float.(value > 0.) -> Or_error.return (value /. 1000.)
    | _ ->
        Or_error.errorf
          "Configuration error: %s=%s is invalid (expected a positive float)"
          name raw
  in
  match trimmed_env "OPENAI_RETRY_MAX_ATTEMPTS" with
  | Some raw -> (
      match parse_positive_int "OPENAI_RETRY_MAX_ATTEMPTS" raw with
      | Error err -> Error err
      | Ok max_attempts -> (
          match trimmed_env "OPENAI_RETRY_BASE_DELAY_MS" with
          | Some delay_raw -> (
              match
                parse_positive_float_ms "OPENAI_RETRY_BASE_DELAY_MS" delay_raw
              with
              | Error err -> Error err
              | Ok initial_delay ->
                  Or_error.return
                    { default_retry_config with max_attempts; initial_delay })
          | None ->
              Or_error.return
                {
                  default_retry_config with
                  max_attempts;
                  initial_delay = default_retry_config.initial_delay;
                }))
  | None -> (
      match trimmed_env "OPENAI_RETRY_BASE_DELAY_MS" with
      | Some delay_raw -> (
          match
            parse_positive_float_ms "OPENAI_RETRY_BASE_DELAY_MS" delay_raw
          with
          | Error err -> Error err
          | Ok initial_delay ->
              Or_error.return { default_retry_config with initial_delay })
      | None -> Or_error.return default_retry_config)

let should_retry_status status =
  match status with
  | 408 | 409 -> true
  | 425 | 429 -> true
  | status when status >= 500 && status < 600 -> true
  | _ -> false

let truncate_body body =
  let max_len = 256 in
  if String.length body <= max_len then body
  else String.prefix body max_len ^ "…"

let should_retry_error_json json =
  let error_type =
    Util.member "type" json |> Util.to_string_option
    |> Option.map ~f:String.lowercase
  in
  match error_type with
  | Some ("server_error" | "timeout" | "rate_limit_error" | "overloaded") ->
      true
  | Some "invalid_request_error" -> false
  | _ ->
      Util.member "code" json |> Util.to_string_option
      |> Option.value_map ~default:false ~f:(fun code ->
             let code = String.lowercase code in
             String.equal code "rate_limit_exceeded"
             || String.equal code "server_error")

let log_retry ~label ~attempt ~max_attempts ~delay error =
  let next_attempt = attempt + 1 in
  eprintf
    "[%s] transient error on attempt %d/%d: %s; retrying in %.2fs before \
     attempt %d\n\
     %!"
    label attempt max_attempts
    (Error.to_string_hum error)
    delay next_attempt
