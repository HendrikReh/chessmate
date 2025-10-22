(** Coordinates fetching candidates, running agent evaluations, and scoring
    results. Rating predicates are cached per summary to avoid redundant work
    and vector scores fall back gracefully when Qdrant is unavailable. *)

open! Base

(** Execute hybrid search by combining Postgres metadata with Qdrant vector
    hits. *)

type agent_status = Agent_disabled | Agent_enabled | Agent_circuit_open

type result = {
  summary : Repo_postgres.game_summary;
  total_score : float;
  vector_score : float;
  keyword_score : float;
  agent_score : float option;
  agent_explanation : string option;
  agent_themes : string list;
  agent_reasoning_effort : Agents_gpt5_client.Effort.t option;
  agent_usage : Agents_gpt5_client.Usage.t option;
  phases : string list;
  themes : string list;
  keywords : string list;
}

type execution = {
  plan : Query_intent.plan;
  results : result list;
  total : int;
  has_more : bool;
  warnings : string list;
  agent_status : agent_status;
}
(** The outcome of executing a hybrid plan. *)

val agent_status_to_string : agent_status -> string
(** Human-readable representation of agent status for logs and API output. *)

val execute :
  fetch_games:(Query_intent.plan -> Repo_postgres.search_page Or_error.t) ->
  fetch_vector_hits:
    (Query_intent.plan ->
    (Hybrid_planner.vector_hit list * string list) Or_error.t) ->
  ?fetch_game_pgns:(int list -> (int * string) list Or_error.t) ->
  ?agent_evaluator:
    (plan:Query_intent.plan ->
    candidates:(Repo_postgres.game_summary * string) list ->
    Agent_evaluator.evaluation list Or_error.t) ->
  ?agent_client:Agents_gpt5_client.t ->
  ?agent_cache:Agent_cache.t ->
  ?agent_timeout_seconds:float ->
  ?agent_candidate_multiplier:int ->
  ?agent_candidate_max:int ->
  Query_intent.plan ->
  execution Or_error.t
(** Run a hybrid query using the supplied data providers. *)
