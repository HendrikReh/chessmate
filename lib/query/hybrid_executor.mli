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

(** Execute hybrid search by combining Postgres metadata with Qdrant vector hits. *)

type result = {
  summary : Repo_postgres.game_summary;
  total_score : float;
  vector_score : float;
  keyword_score : float;
  phases : string list;
  themes : string list;
  keywords : string list;
}

(** The outcome of executing a hybrid plan. *)
type execution = {
  plan : Query_intent.plan;
  results : result list;
  warnings : string list;
}

val execute :
  fetch_games:(Query_intent.plan -> Repo_postgres.game_summary list Or_error.t) ->
  fetch_vector_hits:(Query_intent.plan -> Hybrid_planner.vector_hit list Or_error.t) ->
  Query_intent.plan ->
  execution Or_error.t
(** Run a hybrid query using the supplied data providers. *)
