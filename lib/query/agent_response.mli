(** Parses JSON responses returned by GPT-5 agent prompts. *)

open! Base

type item = {
  game_id : int;
  score : float;
  explanation : string option;
  themes : string list;
}
(** Structured evaluation item returned by the GPT-5 agent. *)

val parse : string -> item list Or_error.t
(** [parse content] parses the JSON payload emitted by the agent into structured
    items. Returns an error when the JSON is malformed or does not conform to
    the expected schema. *)
