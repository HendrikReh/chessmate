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

val stats : t -> Yojson.Safe.t
(** Return lightweight stats (currently max pool size) for diagnostics. *)
