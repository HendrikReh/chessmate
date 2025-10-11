open! Base
open Stdio

(** Emit structured telemetry about GPT-5 evaluations, including token usage and
    optional cost estimates derived from environment configuration. *)

module Effort = Agents_gpt5_client.Effort
module Usage = Agents_gpt5_client.Usage

let truncate_question text =
  let cleaned = String.strip text in
  let limit = 160 in
  if String.length cleaned <= limit then cleaned
  else String.prefix cleaned limit ^ "..."

let tokens_field label value =
  match value with None -> (label, `Null) | Some v -> (label, `Int v)

let float_field label value =
  match value with None -> (label, `Null) | Some v -> (label, `Float v)

let parse_rate name =
  match Stdlib.Sys.getenv_opt name with
  | None -> None
  | Some raw -> (
      let trimmed = String.strip raw in
      if String.is_empty trimmed then None
      else
        match Float.of_string trimmed with
        | exception _ ->
            eprintf "[agent-telemetry] ignoring %s=%s (expected float)\n%!" name
              raw;
            None
        | value when Float.(value < 0.) ->
            eprintf "[agent-telemetry] ignoring %s=%s (must be >= 0)\n%!" name
              raw;
            None
        | value -> Some value)

let pricing_config =
  lazy
    (let input_per_1k = parse_rate "AGENT_COST_INPUT_PER_1K" in
     let output_per_1k = parse_rate "AGENT_COST_OUTPUT_PER_1K" in
     let reasoning_per_1k = parse_rate "AGENT_COST_REASONING_PER_1K" in
     (input_per_1k, output_per_1k, reasoning_per_1k))

let cost_component tokens rate =
  match (tokens, rate) with
  | Some tokens, Some rate -> Some (rate *. Float.of_int tokens /. 1000.)
  | _ -> None

let cost_json usage =
  let input_rate, output_rate, reasoning_rate = Lazy.force pricing_config in
  let input_cost = cost_component usage.Usage.input_tokens input_rate in
  let output_cost = cost_component usage.Usage.output_tokens output_rate in
  let reasoning_cost =
    cost_component usage.Usage.reasoning_tokens reasoning_rate
  in
  let total_cost =
    match
      List.filter_map [ input_cost; output_cost; reasoning_cost ] ~f:Fn.id
    with
    | [] -> None
    | values ->
        let sum = List.fold values ~init:0.0 ~f:( +. ) in
        if Float.(sum <= 0.) then None else Some sum
  in
  if
    Option.is_none total_cost && Option.is_none input_cost
    && Option.is_none output_cost
    && Option.is_none reasoning_cost
  then `Null
  else
    `Assoc
      [
        float_field "total" total_cost;
        float_field "input" input_cost;
        float_field "output" output_cost;
        float_field "reasoning" reasoning_cost;
      ]

let log ~plan ~candidate_count ~evaluated ~effort ~latency_ms ~usage =
  let timestamp_ms = Unix.gettimeofday () *. 1000.0 in
  let question = truncate_question plan.Query_intent.cleaned_text in
  let tokens_json =
    `Assoc
      [
        tokens_field "input" usage.Usage.input_tokens;
        tokens_field "output" usage.Usage.output_tokens;
        tokens_field "reasoning" usage.Usage.reasoning_tokens;
      ]
  in
  let json =
    `Assoc
      [
        ("event", `String "agent_evaluation");
        ("timestamp_ms", `Float timestamp_ms);
        ("question", `String question);
        ("candidate_count", `Int candidate_count);
        ("evaluated", `Int evaluated);
        ("reasoning_effort", `String (Effort.to_string effort));
        ("latency_ms", `Float latency_ms);
        ("tokens", tokens_json);
        ("cost", cost_json usage);
      ]
  in
  eprintf "[agent-telemetry] %s\n%!" (Yojson.Safe.to_string json)
