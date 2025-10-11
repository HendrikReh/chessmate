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

(* Legacy CLI that converts PGN files into FEN sequences. *)

open! Base
open Stdio
open Chessmate

let usage = "Usage: pgn_to_fen <input.pgn> [output.txt]"

let exit_with_error err =
  eprintf "Error: %s\n" (Error.to_string_hum err);
  Stdlib.exit 1

let () =
  match Array.to_list Stdlib.Sys.argv |> List.tl with
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
