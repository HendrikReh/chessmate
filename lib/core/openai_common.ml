(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search *)

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

let parse_env_int name ~default =
  match Stdlib.Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      match Int.of_string_opt (String.strip raw) with
      | Some value when value > 0 -> value
      | _ -> default)

let parse_env_float_ms name ~default =
  match Stdlib.Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      match Float.of_string (String.strip raw) with
      | exception _ -> default
      | value when Float.(value > 0.) -> value /. 1000.
      | _ -> default)

let load_retry_config () =
  let max_attempts = parse_env_int "OPENAI_RETRY_MAX_ATTEMPTS" ~default:default_retry_config.max_attempts in
  let initial_delay =
    parse_env_float_ms "OPENAI_RETRY_BASE_DELAY_MS" ~default:default_retry_config.initial_delay
  in
  { default_retry_config with max_attempts; initial_delay }

let should_retry_status status =
  match status with
  | 408 | 409 -> true
  | 425 | 429 -> true
  | status when status >= 500 && status < 600 -> true
  | _ -> false

let truncate_body body =
  let max_len = 256 in
  if String.length body <= max_len then body else String.prefix body max_len ^ "…"

let should_retry_error_json json =
  let error_type =
    Util.member "type" json |> Util.to_string_option |> Option.map ~f:String.lowercase
  in
  match error_type with
  | Some ("server_error" | "timeout" | "rate_limit_error" | "overloaded") -> true
  | Some "invalid_request_error" -> false
  | _ ->
      Util.member "code" json
      |> Util.to_string_option
      |> Option.value_map ~default:false ~f:(fun code ->
             let code = String.lowercase code in
             String.equal code "rate_limit_exceeded" || String.equal code "server_error")

let log_retry ~label ~attempt ~max_attempts ~delay error =
  let next_attempt = attempt + 1 in
  eprintf
    "[%s] transient error on attempt %d/%d: %s; retrying in %.2fs before attempt %d\n%!"
    label attempt max_attempts (Error.to_string_hum error) delay next_attempt
