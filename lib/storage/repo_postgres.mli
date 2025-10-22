(** High-level Postgres repository for ingesting games, managing embedding jobs,
    and serving query metadata. *)

open! Base

type t
(** Thin wrapper around {!Repo_postgres_caqti.t} kept for backwards
    compatibility. *)

val create : string -> t Or_error.t
(** Create the shared repository state used by CLI/worker/API. *)

type pool_stats = {
  capacity : int;
  in_use : int;
  available : int;
  waiting : int;
}

val pool_stats : t -> pool_stats
(** Read pool utilisation stats for diagnostics/metrics. *)

val insert_game :
  t ->
  metadata:Game_metadata.t ->
  pgn:string ->
  moves:Pgn_parser.move list ->
  (int * int) Or_error.t
(** Persist a parsed game and its moves. Returns
    [(game_id, inserted_positions)]. *)

type game_summary = Repo_postgres_caqti.game_summary = {
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

type search_page = { games : game_summary list; total : int }

val search_games :
  t ->
  filters:Query_intent.metadata_filter list ->
  rating:Query_intent.rating_filter ->
  limit:int ->
  offset:int ->
  search_page Or_error.t

val pending_embedding_job_count : t -> int Or_error.t
val fetch_games_with_pgn : t -> ids:int list -> (int * string) list Or_error.t
val claim_pending_jobs : t -> limit:int -> Embedding_job.t list Or_error.t
val mark_job_completed : t -> job_id:int -> vector_id:string -> unit Or_error.t
val mark_job_failed : t -> job_id:int -> error:string -> unit Or_error.t

type vector_payload = { position_id : int; game_id : int; json : Yojson.Safe.t }

val vector_payload_for_job : t -> job_id:int -> vector_payload Or_error.t

module Private : sig
  val build_conditions :
    filters:Query_intent.metadata_filter list ->
    rating:Query_intent.rating_filter ->
    string list * string option list * int
end
