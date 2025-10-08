(* Emits structured telemetry for GPT-5 agent calls (latency, tokens, cost). *)

(** Emits structured telemetry for GPT-5 agent calls. *)

open! Base

val log :
  plan:Query_intent.plan ->
  candidate_count:int ->
  evaluated:int ->
  effort:Agents_gpt5_client.Effort.t ->
  latency_ms:float ->
  usage:Agents_gpt5_client.Usage.t ->
  unit
(** Emit structured telemetry for an agent evaluation round. The log contains the
    question, candidate counts, reasoning effort, latency, token usage, and optional cost
    estimates derived from environment configuration. *)
