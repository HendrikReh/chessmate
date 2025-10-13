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

(** Emits structured telemetry for GPT-5 agent calls (latency, tokens, cost). *)

open! Base

val log :
  plan:Query_intent.plan ->
  candidate_count:int ->
  evaluated:int ->
  effort:Agents_gpt5_client.Effort.t ->
  latency_ms:float ->
  usage:Agents_gpt5_client.Usage.t ->
  unit
(** Emit structured telemetry for an agent evaluation round. The log contains
    the question, candidate counts, reasoning effort, latency, token usage, and
    optional cost estimates derived from environment configuration. *)
