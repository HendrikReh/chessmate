open! Base

type t = (string, float array, String.comparator_witness) Map.t ref

let create () = ref (Map.empty (module String))

let find cache key = Map.find !cache key

let add cache key value =
  cache := Map.set !cache ~key ~data:value
