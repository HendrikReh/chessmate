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

(** Storage facade for PostgreSQL interactions. *)

type t

val create : string -> t Or_error.t
(** Initialize a repository using a database connection string. *)

val insert_game :
  t ->
  metadata:Game_metadata.t ->
  pgn:string ->
  moves:Pgn_parser.move list ->
  (int * int) Or_error.t
(** Persist a parsed game and its moves. Returns [(game_id, inserted_positions)]. *)

type game_summary = {
  id : int;
  white : string;
  black : string;
  result : string option;
  event : string option;
  opening_slug : string option;
  opening_name : string option;
  eco_code : string option;
  white_rating : int option;
  black_rating : int option;
  played_on : string option;
}

val search_games :
  t ->
  filters:Query_intent.metadata_filter list ->
  rating:Query_intent.rating_filter ->
  limit:int ->
  game_summary list Or_error.t

val fetch_pending_jobs : t -> limit:int -> Embedding_job.t list Or_error.t
val mark_job_started : t -> job_id:int -> unit Or_error.t
val mark_job_completed : t -> job_id:int -> vector_id:string -> unit Or_error.t
val mark_job_failed : t -> job_id:int -> error:string -> unit Or_error.t
