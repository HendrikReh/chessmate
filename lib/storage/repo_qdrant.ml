open! Base

type t = string

type point_id = string

let create base_url =
  if String.is_empty base_url then
    Or_error.error_string "Qdrant base URL cannot be empty"
  else
    Ok base_url

let upsert_point (_t : t) (_id : point_id) ~vector:_ ~payload:_ =
  Or_error.error_string "Qdrant upsert_point not implemented yet"
