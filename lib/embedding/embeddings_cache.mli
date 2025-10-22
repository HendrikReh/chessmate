(** Lightweight in-memory cache for already-computed embeddings, primarily for
    tests and local development. *)

type t
(** Simple in-memory cache keyed by FEN. *)

val create : unit -> t [@@ocaml.doc "Initialise an empty cache."]

val find : t -> string -> float array option
[@@ocaml.doc "Retrieve a cached embedding (keyed by FEN)."]

val add : t -> string -> float array -> unit
[@@ocaml.doc "Store a computed embedding in the cache."]
