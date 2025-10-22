(** Provide the `chessmate fen` helper that streams PGN moves to stdout as FEN
    snapshots or writes them to a file. *)

open! Base
open Stdio

let ( let* ) t f = Or_error.bind t ~f

(* Writes each FEN on its own line to the provided channel. *)
let write_fens channel fens =
  List.iter fens ~f:(fun fen ->
      Out_channel.output_string channel fen;
      Out_channel.newline channel);
  Out_channel.flush channel

let run ~input ~output =
  let* fens =
    Pgn_to_fen.fens_of_file input
    |> Or_error.tag ~tag:(Printf.sprintf "failed to derive FENs for %s" input)
  in
  match output with
  | None ->
      write_fens Out_channel.stdout fens;
      Or_error.return ()
  | Some path ->
      Or_error.try_with (fun () ->
          Out_channel.with_file path ~f:(fun oc -> write_fens oc fens))
