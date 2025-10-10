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
