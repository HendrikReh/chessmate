(** OpenAI embeddings client used by ingestion/worker paths to batch FEN
    requests with chunk guards and retry/backoff. *)

open! Base

type t
(** Client handle encapsulating retry configuration and HTTP state. *)

val create : api_key:string -> endpoint:string -> t Or_error.t
[@@ocaml.doc
  "Initialise a client targeting the given OpenAI endpoint with the supplied \
   api_key."]

val embed_fens : t -> string list -> float array list Or_error.t
[@@ocaml.doc
  "Batch request embeddings for FEN strings using the OpenAI embeddings REST \
   API. Requests automatically retry on transient HTTP failures (429, 5xx, \
   etc.) using exponential backoff. Configure retry behaviour via the optional \
   environment variables OPENAI_RETRY_MAX_ATTEMPTS and \
   OPENAI_RETRY_BASE_DELAY_MS. Requests are chunked (defaults: 2048 inputs, \
   ~120k characters) to respect provider limits; override via \
   OPENAI_EMBEDDING_CHUNK_SIZE / OPENAI_EMBEDDING_MAX_CHARS."]

module Private : sig
  val chunk_list : 'a list -> chunk_size:int -> 'a list list
  [@@ocaml.doc "Split a list into chunks of size chunk_size."]

  val enforce_char_limit : string list -> max_chars:int -> string list list
  [@@ocaml.doc "Break input batches so that each chunk stays under max_chars."]

  val total_chars : string list -> int
  [@@ocaml.doc "Sum the UTF-8 character count across inputs."]
end
