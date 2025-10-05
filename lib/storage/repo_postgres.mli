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
(** Persist a parsed game and its moves. Returns [(game_id, inserted_positions)].
    Currently a stub until the PostgreSQL driver is integrated. *)
