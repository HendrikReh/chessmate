open! Base

(** Caqti-backed repository wrapper around the Chessmate Postgres schema.

    This module owns the connection pool that is handed to all services (CLI,
    API, embedding worker). Public functions mirror the operations the system
    performs today: inserting parsed PGNs, reading back metadata for hybrid
    search, and managing the embedding job lifecycle.

    The interface purposefully exposes only Or_error-returning helpers so
    callers inherit a consistent error-reporting story without depending on
    Caqti-specific exceptions. *)

type t
(** Abstract handle to the shared connection pool. *)

val create : ?pool_size:int -> string -> t Or_error.t
(** [create ?pool_size uri] initialises a blocking Caqti pool targeting the
    given connection [uri]. When [pool_size] is omitted the pool honours
    [CHESSMATE_DB_POOL_SIZE] (default 10). *)

val with_connection :
  t ->
  (Caqti_blocking.connection -> ('a, Caqti_error.t) Result.t) ->
  'a Or_error.t
(** [with_connection repo f] borrows a connection from [repo]'s pool, executes
    [f], and returns the result as an [Or_error]. The connection is returned to
    the pool regardless of success/failure. *)

val disconnect : t -> unit
(** Drain and dispose the underlying pool (used mainly in tests). *)

type stats = { capacity : int; in_use : int; waiting : int }

val stats : t -> stats
(** Snapshot the current pool utilisation (exposed via [/metrics]). *)

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

type search_page = { games : game_summary list; total : int }

val search_games :
  t ->
  filters:Query_intent.metadata_filter list ->
  rating:Query_intent.rating_filter ->
  limit:int ->
  offset:int ->
  search_page Or_error.t
(** Search the [games] table using the same metadata filters the hybrid planner
    produces (opening slug, ECO range, rating bounds, etc.). Results are ordered
    by [played_on DESC, id DESC], constrained to [limit], offset by [offset],
    and accompanied by the total number of matching games. *)

val pending_embedding_job_count : t -> int Or_error.t
(** Count jobs in [embedding_jobs] that are still marked [pending]. *)

val fetch_games_with_pgn : t -> ids:int list -> (int * string) list Or_error.t
(** Fetch raw PGN blobs for the provided game ids. *)

val insert_game :
  t ->
  metadata:Game_metadata.t ->
  pgn:string ->
  moves:Pgn_parser.move list ->
  (int * int) Or_error.t
(** Persist a parsed PGN:
    - upsert players,
    - insert a game row,
    - insert per-ply positions and enqueue embedding jobs.

    Returns [(game_id, inserted_position_count)]. *)

val claim_pending_jobs : t -> limit:int -> Embedding_job.t list Or_error.t
(** Atomically claim up to [limit] pending embedding jobs using
    [FOR UPDATE SKIP LOCKED]. Claimed jobs transition to [in_progress]. *)

val mark_job_completed : t -> job_id:int -> vector_id:string -> unit Or_error.t
(** Mark an embedding job [completed] and push [vector_id] into
    [positions.vector_id]. *)

val mark_job_failed : t -> job_id:int -> error:string -> unit Or_error.t
(** Record an embedding job failure with a sanitized [error] message. *)

type vector_payload = { position_id : int; game_id : int; json : Yojson.Safe.t }

val vector_payload_for_job : t -> job_id:int -> vector_payload Or_error.t
(** Load the metadata used to build a Qdrant payload (game/position fields plus
    denormalised player/opening stats). *)

module Private : sig
  val build_conditions :
    filters:Query_intent.metadata_filter list ->
    rating:Query_intent.rating_filter ->
    string list * string option list * int
end
