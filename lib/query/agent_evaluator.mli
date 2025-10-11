(** Prepares candidate context, invokes GPT-5, and normalises scores/explanations. *)

open! Base

type evaluation = {
  game_id : int;
  (** Candidate identifier (Postgres game id). *)
  score : float;
  (** Agent-provided score in the [0.0, 1.0] range. *)
  explanation : string option;
  (** Optional explanation extracted from the agent response. *)
  themes : string list;
  (** Highlighted themes/tactics detected by the agent. *)
  reasoning_effort : Agents_gpt5_client.Effort.t;
  (** Effort level mirroring the request configuration. *)
  usage : Agents_gpt5_client.Usage.t option;
  (** Token usage telemetry when the provider returns it. *)
}

val evaluate :
  client:Agents_gpt5_client.t ->
  plan:Query_intent.plan ->
  candidates:(Repo_postgres.game_summary * string) list ->
  evaluation list Or_error.t
(** Call GPT-5 for each candidate. Missing entries are ignored; callers handle caching and error propagation. *)
