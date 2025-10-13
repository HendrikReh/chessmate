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

(** Prepares candidate context, invokes GPT-5, and normalises
    scores/explanations. *)

open! Base

type evaluation = {
  game_id : int;  (** Candidate identifier (Postgres game id). *)
  score : float;  (** Agent-provided score in the [0.0, 1.0] range. *)
  explanation : string option;
      (** Optional explanation extracted from the agent response. *)
  themes : string list;
      (** Highlighted themes/tactics detected by the agent. *)
  reasoning_effort : Agents_gpt5_client.Effort.t;
      (** Effort level mirroring the request configuration. *)
  usage : Agents_gpt5_client.Usage.t option;
      (** Token usage telemetry when the provider returns it. *)
}

val evaluate :
  client:Agents_gpt5_client.t ->
  plan:Query_intent.plan ->
  candidates:(Repo_postgres.game_summary * string) list ->
  evaluation list Or_error.t
(** Call GPT-5 for each candidate. Missing entries are ignored; callers handle
    caching and error propagation. *)
