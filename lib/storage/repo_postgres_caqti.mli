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

module Private : sig
  val build_conditions :
    filters:Query_intent.metadata_filter list ->
    rating:Query_intent.rating_filter ->
    string list * string option list * int
end
