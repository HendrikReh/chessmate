(** Assemble ranked results into human-readable summaries for the CLI and rich
    JSON payloads for the HTTP API. *)

open! Base

type game_ref = { game_id : int; white : string; black : string; score : float }

let summarize games =
  let count = Int.min 5 (List.length games) in
  let top_games = List.take games count in
  top_games
  |> List.map ~f:(fun g ->
         Printf.sprintf "#%d %s vs %s (score %.2f)" g.game_id g.white g.black
           g.score)
  |> String.concat ~sep:"\n"
