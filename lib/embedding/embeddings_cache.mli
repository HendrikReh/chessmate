(** Lightweight cache for already-computed embeddings. *)

type t

val create : unit -> t
val find : t -> string -> float array option
val add : t -> string -> float array -> unit
