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

(* Dedicated configuration sanity checks for the CLI. *)

open! Base
open Stdio

let suggestions_for message =
  let message_lower = String.lowercase message in
  let table =
    [
      ( "database_url",
        "Set DATABASE_URL to your Postgres connection string (e.g. export \
         DATABASE_URL=...)." );
      ( "qdrant_url",
        "Set QDRANT_URL to your Qdrant endpoint (e.g. export \
         QDRANT_URL=http://localhost:6333)." );
      ( "openai_retry_max_attempts",
        "Ensure OPENAI_RETRY_MAX_ATTEMPTS is a positive integer or unset to \
         use defaults." );
      ( "openai_retry_base_delay_ms",
        "Ensure OPENAI_RETRY_BASE_DELAY_MS is a positive number of \
         milliseconds or unset to use defaults." );
      ( "agent_api_key",
        "Provide AGENT_API_KEY so API queries can contact the reasoning agent."
      );
      ( "agent_cache_redis_url",
        "Set AGENT_CACHE_REDIS_URL (and optionally TTL/capacity) to enable \
         agent caching, or unset to disable." );
    ]
  in
  table
  |> List.filter_map ~f:(fun (needle, hint) ->
         if String.is_substring message_lower ~substring:needle then Some hint
         else None)

let print_statuses (summary : Service_health.summary) =
  List.iter summary.statuses ~f:(fun status ->
      printf "%s\n" (Service_health.status_line status))

let run () =
  match Service_health.check () with
  | Error err ->
      eprintf "Configuration checks aborted: %s\n" (Error.to_string_hum err);
      Stdlib.exit 1
  | Ok summary -> (
      print_statuses summary;
      let open Service_health in
      match summary.fatal with
      | Some { name; availability = Unavailable reason; _ } ->
          eprintf "Configuration check failed: %s unavailable: %s\n" name reason;
          List.iter (suggestions_for reason) ~f:(fun hint ->
              eprintf "  hint: %s\n" hint);
          Stdlib.exit 1
      | Some status ->
          eprintf "Configuration check failed: %s\n" (status_line status);
          Stdlib.exit 1
      | None ->
          if not (List.is_empty summary.warnings) then (
            printf
              "Configuration checks completed with warnings (optional \
               dependencies).\n";
            Stdlib.exit 2)
          else (
            printf "All configuration checks passed.\n";
            Stdlib.exit 0))
