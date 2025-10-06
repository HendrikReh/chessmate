open! Base

(** Interface to OpenAI embeddings. *)

type t

val create : api_key:string -> endpoint:string -> t Or_error.t
val embed_fens : t -> string list -> float array list Or_error.t
(** Batch request embeddings for FEN strings using the OpenAI embeddings REST API. *)
