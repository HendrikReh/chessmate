(** In-memory queue abstraction used by ingestion tests before hitting the
    persistent embedding_jobs table. *)

open! Base

type job = { fen : string; metadata : (string * string) list }
type t

val create : unit -> t
val enqueue : t -> job -> unit Or_error.t
val dequeue_batch : t -> int -> job list Or_error.t
