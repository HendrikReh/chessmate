(** Translate natural-language questions into structured filters. *)

type rating_filter = {
  white_min : int option;
  black_max_delta : int option;
}

type request = {
  text : string;
}

type plan = {
  filters : (string * string) list;
  rating : rating_filter;
}

val analyse : request -> plan
