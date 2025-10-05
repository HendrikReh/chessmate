(** Format search results for CLI/API responses. *)

type game_ref = {
  game_id : int;
  white : string;
  black : string;
  score : float;
}

val summarize : game_ref list -> string
