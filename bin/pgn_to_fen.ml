(* Legacy CLI that converts PGN files into FEN sequences. *)

open! Base
open Stdio
open Chessmate

let usage = "Usage: pgn_to_fen <input.pgn> [output.txt]"

let exit_with_error err =
  eprintf "Error: %s\n" (Error.to_string_hum err);
  Stdlib.exit 1

let run ?argv () =
  let argv = Option.value argv ~default:Stdlib.Sys.argv in
  match Array.to_list argv |> List.tl with
  | Some [ input ] -> (
      match Pgn_to_fen_command.run ~input ~output:None with
      | Ok () -> ()
      | Error err -> exit_with_error err)
  | Some [ input; output ] -> (
      match Pgn_to_fen_command.run ~input ~output:(Some output) with
      | Ok () -> ()
      | Error err -> exit_with_error err)
  | _ ->
      eprintf "%s\n" usage;
      Stdlib.exit 1

let () = run ()
