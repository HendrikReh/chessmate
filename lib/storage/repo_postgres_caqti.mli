open! Base

(** Experimental Caqti-backed Postgres pool. *)

type t

val create : ?pool_size:int -> string -> t Or_error.t
(** Create a connection pool targeting the given connection URI. *)

val with_connection :
  t ->
  (Caqti_blocking.connection -> ('a, Caqti_error.t) Result.t) ->
  'a Or_error.t
(** Execute [f] with a pooled connection, mapping Caqti errors into [Or_error]. *)

val disconnect : t -> unit
(** Drain the pool and close all connections. *)

type stats = {
  capacity : int;
  in_use : int;
  waiting : int;
}

val stats : t -> stats
(** Return pool utilisation statistics. *)

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

val pending_embedding_job_count : t -> int Or_error.t

val fetch_games_with_pgn :
  t -> ids:int list -> (int * string) list Or_error.t

val insert_game :
  t ->
  metadata:Game_metadata.t ->
  pgn:string ->
  moves:Pgn_parser.move list ->
  (int * int) Or_error.t

val claim_pending_jobs : t -> limit:int -> Embedding_job.t list Or_error.t
val mark_job_completed : t -> job_id:int -> vector_id:string -> unit Or_error.t
val mark_job_failed : t -> job_id:int -> error:string -> unit Or_error.t

type vector_payload = {
  position_id : int;
  game_id : int;
  json : Yojson.Safe.t;
}

val vector_payload_for_job : t -> job_id:int -> vector_payload Or_error.t

module Private : sig
  val build_conditions :
    filters:Query_intent.metadata_filter list ->
    rating:Query_intent.rating_filter ->
    string list * string option list * int
end
