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

let redaction = "[redacted]"

let sanitize_patterns =
  let patterns =
    [
      "sk-[A-Za-z0-9_-]{8,}";
      "gpt-[A-Za-z0-9_-]{8,}";
      "OPENAI_API_KEY=[^\\s]+";
      "DATABASE_URL=[^\\s]+";
      "postgres://[^\\s]+";
      "postgresql://[^\\s]+";
      "redis://[^\\s]+";
      "AGENT_API_KEY=[^\\s]+";
    ]
  in
  List.map patterns ~f:Re.Posix.compile_pat

let sanitize_string text =
  List.fold sanitize_patterns ~init:text ~f:(fun acc regex ->
      Re.replace ~all:true regex ~f:(fun _ -> redaction) acc)

let sanitize_error err = Error.to_string_hum err |> sanitize_string
