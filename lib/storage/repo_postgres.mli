open! Base

(** Storage facade for PostgreSQL interactions. *)

type t

val create : string -> t Or_error.t
(** Initialize a repository using a database connection string. *)

val insert_game : t -> Game_metadata.t -> string -> (int * int) Or_error.t
(** Persist game metadata and raw PGN. Returns [(game_id, inserted_rows)]. Currently stubbed. *)
