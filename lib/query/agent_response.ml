open! Base

module Util = Yojson.Safe.Util

type item = {
  game_id : int;
  score : float;
  explanation : string option;
  themes : string list;
}

let parse content =
  try
    let json = Yojson.Safe.from_string content in
    let open Util in
    let items = json |> member "evaluations" |> to_list in
    let parse_item item =
      match member "game_id" item |> to_int_option, member "score" item |> to_float_option with
      | Some game_id, Some score ->
          let explanation = member "explanation" item |> to_string_option in
          let themes =
            match member "themes" item with
            | `Null -> []
            | json_themes ->
                json_themes
                |> to_list
                |> List.filter_map ~f:to_string_option
          in
          Some { game_id; score; explanation; themes }
      | _ -> None
    in
    items
    |> List.filter_map ~f:parse_item
    |> Or_error.return
  with
  | Yojson.Json_error msg | Util.Type_error (msg, _) -> Or_error.error_string msg
