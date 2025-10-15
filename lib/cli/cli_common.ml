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
