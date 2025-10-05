open! Base

(** Wrapper around Qdrant HTTP API. *)

type t

type point_id = string

val create : string -> t Or_error.t
(** Create a client targeting the provided base URL. *)

val upsert_point :
  t ->
  point_id ->
  vector:float array ->
  payload:(string * string) list ->
  unit Or_error.t
(** Upsert a single point. Currently a stub returning an error. *)
