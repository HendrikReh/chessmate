(** Helpers converting domain types into Qdrant payloads. *)

val from_metadata :
  Game_metadata.t -> extra:(string * string) list -> (string * string) list
(** Serialise metadata into key/value pairs stored alongside vectors in Qdrant.
    [extra] allows callers to append additional fields (e.g. FEN, vector_id). *)
