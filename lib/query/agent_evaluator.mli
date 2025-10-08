open! Base

(** Evaluation returned by the GPT-5 agent. *)
type evaluation = {
  game_id : int;
  score : float;
  explanation : string option;
  themes : string list;
  reasoning_effort : Agents_gpt5_client.Effort.t;
  usage : Agents_gpt5_client.Usage.t option;
}

(** Evaluate candidate games using GPT-5. [candidates] pairs a game summary with its PGN. *)
val evaluate :
  client:Agents_gpt5_client.t ->
  plan:Query_intent.plan ->
  candidates:(Repo_postgres.game_summary * string) list ->
  evaluation list Or_error.t
(** The agent returns a list of evaluations (one per candidate provided). Scores are expected
    to be normalised in [0.0, 1.0]; candidates missing from the response are ignored. *)
