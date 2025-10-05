(** Helpers converting domain types into Qdrant payloads. *)

val from_metadata : Game_metadata.t -> extra:(string * string) list -> (string * string) list
