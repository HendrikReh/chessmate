(*  Chessmate - Hybrid chess tutor combining Postgres metadata with Qdrant
    vector search
    Copyright (C) 2025 Hendrik Reh <hendrik.reh@blacksmith-consulting.ai>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*)

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
