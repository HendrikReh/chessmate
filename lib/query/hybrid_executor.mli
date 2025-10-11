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

(** Coordinates fetching candidates, running agent evaluations, and scoring
    results. *)

open! Base

(** Execute hybrid search by combining Postgres metadata with Qdrant vector
    hits. *)

type result = {
  summary : Repo_postgres.game_summary;
  total_score : float;
  vector_score : float;
  keyword_score : float;
  agent_score : float option;
  agent_explanation : string option;
  agent_themes : string list;
  agent_reasoning_effort : Agents_gpt5_client.Effort.t option;
  agent_usage : Agents_gpt5_client.Usage.t option;
  phases : string list;
  themes : string list;
  keywords : string list;
}

type execution = {
  plan : Query_intent.plan;
  results : result list;
  warnings : string list;
}
(** The outcome of executing a hybrid plan. *)

val execute :
  fetch_games:(Query_intent.plan -> Repo_postgres.game_summary list Or_error.t) ->
  fetch_vector_hits:
    (Query_intent.plan -> Hybrid_planner.vector_hit list Or_error.t) ->
  ?fetch_game_pgns:(int list -> (int * string) list Or_error.t) ->
  ?agent_evaluator:
    (plan:Query_intent.plan ->
    candidates:(Repo_postgres.game_summary * string) list ->
    Agent_evaluator.evaluation list Or_error.t) ->
  ?agent_client:Agents_gpt5_client.t ->
  ?agent_cache:Agent_cache.t ->
  Query_intent.plan ->
  execution Or_error.t
(** Run a hybrid query using the supplied data providers. *)
