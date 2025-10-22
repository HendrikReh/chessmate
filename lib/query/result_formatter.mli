(** Format search results for CLI/API responses. *)

type game_ref = { game_id : int; white : string; black : string; score : float }
(** Lightweight projection used for CLI summaries. [score] is already normalised
    (0.0–1.0). *)

val summarize : game_ref list -> string
(** Render a short multi-line summary suitable for CLI output. *)
