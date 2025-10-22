(** Shared helpers for CLI commands: environment validation, URL resolution, and
    formatted error handling. *)

open! Base

let with_db_url f =
  match Config.Cli.database_url () with
  | Ok url -> f url
  | Error err -> Error err

let api_base_url () = Config.Cli.api_base_url ()

let positive_int_from_env ~name ~default =
  match Config.Helpers.optional name with
  | None -> Or_error.return default
  | Some raw -> Config.Helpers.parse_positive_int name raw

let positive_float_from_env ~name ~default =
  match Config.Helpers.optional name with
  | None -> Or_error.return default
  | Some raw -> (
      match Float.of_string raw with
      | exception _ ->
          Config.Helpers.invalid name raw "expected a positive floating value"
      | value when Float.(value > 0.) -> Or_error.return value
      | _ ->
          Config.Helpers.invalid name raw "expected a positive floating value")

let prometheus_port_from_env () =
  match Config.Helpers.optional "CHESSMATE_PROM_PORT" with
  | None -> Or_error.return None
  | Some raw -> (
      match Config.Helpers.parse_positive_int "CHESSMATE_PROM_PORT" raw with
      | Error err -> Error err
      | Ok port ->
          if port > 65_535 then
            Config.Helpers.invalid "CHESSMATE_PROM_PORT" raw
              "expected a TCP port (1-65535)"
          else Or_error.return (Some port))
