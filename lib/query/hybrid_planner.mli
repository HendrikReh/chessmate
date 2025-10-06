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

(** Build hybrid Qdrant + SQL requests from analysed intent. *)

type t = {
  vector_weight : float;
  keyword_weight : float;
}

val default : t

val scoring_weights : t -> vector:float -> keyword:float -> float

val build_payload_filters : Query_intent.plan -> Yojson.Safe.t list option
(** Convert a query plan into Qdrant payload filter clauses. *)

val query_vector : Query_intent.plan -> float list
(** Deterministically derive a query embedding from the analysed intent. *)

type vector_hit = {
  game_id : int;
  score : float;
  phases : string list;
  themes : string list;
  keywords : string list;
}

val vector_hits_of_points : Repo_qdrant.scored_point list -> vector_hit list
(** Parse Qdrant scored points into typed vector hits. *)

val index_hits_by_game : vector_hit list -> vector_hit Map.M(Int).t
(** Group vector hits by referenced game id. *)

val normalize_vector_score : float -> float
(** Normalise raw Qdrant scores into the 0.0–1.0 range. *)

val merge_keywords : string list -> string list -> string list
val merge_phases : string list -> string list -> string list
val merge_themes : string list -> string list -> string list
(** Deduplicate and merge metadata coming from SQL and Qdrant sources. *)
