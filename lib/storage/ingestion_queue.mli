open! Base

(** Simple interface for managing ingestion jobs. *)

type job = {
  fen : string;
  metadata : (string * string) list;
}

type t

val create : unit -> t
val enqueue : t -> job -> unit Or_error.t
val dequeue_batch : t -> int -> job list Or_error.t
