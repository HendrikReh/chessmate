open! Base

type t = {
  vector_weight : float;
  keyword_weight : float;
}

let default = { vector_weight = 0.7; keyword_weight = 0.3 }

let build_payload_filters plan = plan.Query_intent.filters

let scoring_weights t ~vector ~keyword =
  (t.vector_weight *. vector) +. (t.keyword_weight *. keyword)
