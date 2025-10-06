(** Types summarizing chess game metadata. *)

type player = {
  name : string;
  fide_id : string option;
  rating : int option;
}

type t = {
  event : string option;
  site : string option;
  date : string option;
  round : string option;
  white : player;
  black : player;
  eco_code : string option;
  result : string option;
}

val empty_player : player
val empty : t
val of_headers : (string * string) list -> t
