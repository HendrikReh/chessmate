open! Base

module Evaluation = Agent_evaluator

module Key = struct
  type t = string

  let of_plan ~plan ~summary ~pgn =
    let digest_source =
      String.concat ~sep:"\n"
        [ plan.Query_intent.cleaned_text
        ; String.concat ~sep:"," plan.Query_intent.keywords
        ; Int.to_string plan.Query_intent.limit
        ; Option.value plan.Query_intent.rating.white_min ~default:(-1) |> Int.to_string
        ; Option.value plan.Query_intent.rating.black_min ~default:(-1) |> Int.to_string
        ; Option.value plan.Query_intent.rating.max_rating_delta ~default:(-1) |> Int.to_string
        ; Option.value summary.Repo_postgres.opening_slug ~default:""
        ; Option.value summary.Repo_postgres.result ~default:""
        ; pgn
        ]
    in
    Stdlib.Digest.string digest_source |> Stdlib.Digest.to_hex
end

type key = Key.t

type entry = Evaluation.evaluation

type t = {
  capacity : int;
  table : entry Hashtbl.M(String).t;
  order : key Queue.t;
}

let create ~capacity =
  let capacity = Int.max 1 capacity in
  { capacity; table = Hashtbl.create (module String); order = Queue.create () }

let capacity t = t.capacity
let size t = Hashtbl.length t.table

let rec evict_if_needed t =
  if size t <= t.capacity then ()
  else
    match Queue.dequeue t.order with
    | None -> ()
    | Some old_key ->
        Hashtbl.remove t.table old_key;
        evict_if_needed t

let find t key = Hashtbl.find t.table key

let store t key value =
  if not (Hashtbl.mem t.table key) then Queue.enqueue t.order key;
  Hashtbl.set t.table ~key ~data:value;
  evict_if_needed t

let key_of_plan = Key.of_plan
