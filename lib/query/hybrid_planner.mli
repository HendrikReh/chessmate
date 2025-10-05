open! Base

(** Build hybrid Qdrant + SQL requests from analysed intent. *)

type t = {
  vector_weight : float;
  keyword_weight : float;
}

val default : t

val build_payload_filters : Query_intent.plan -> (string * string) list
val scoring_weights : t -> vector:float -> keyword:float -> float
