(** Derived features for FEN snapshots, used during embeddings and filters. *)

type theme = Unknown | KingsideAttack | QueensideMajority | CentralBreak

val theme_of_tags : string list -> theme
(** Naive classifier turning PGN tags/comments into coarse themes. *)

val to_payload_fragments : theme -> (string * string) list
(** Convert derived theme into key/value pairs for storage payloads. *)
