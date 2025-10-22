(** Build the JSON payload sent to Qdrant for each embedding, combining player
    metadata, tags, and runtime extras. *)

open! Base

let from_metadata metadata ~extra =
  let base =
    [
      ("white_name", metadata.Game_metadata.white.name);
      ("black_name", metadata.Game_metadata.black.name);
    ]
    |> List.filter ~f:(fun (_k, v) -> not (String.is_empty v))
  in
  List.concat [ base; extra ]
