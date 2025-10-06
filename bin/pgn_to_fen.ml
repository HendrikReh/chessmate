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

open! Base
open Stdio

let usage () =
  eprintf "Usage: pgn_to_fen <input.pgn> [output.txt]\n";
  Stdlib.exit 1

let write_fens channel fens =
  List.iter fens ~f:(fun fen -> Out_channel.output_string channel fen; Out_channel.output_char channel '\n')

let main input output =
  match Chessmate.Pgn_to_fen.fens_of_file input with
  | Error err ->
      eprintf "pgn_to_fen: %s\n" (Error.to_string_hum err);
      Stdlib.exit 1
  | Ok fens ->
      (match output with
       | None -> write_fens stdout fens
       | Some path -> Out_channel.with_file path ~f:(fun oc -> write_fens oc fens))

let () =
  match Array.to_list Stdlib.Sys.argv |> List.tl with
  | Some [ input ] -> main input None
  | Some [ input; output ] -> main input (Some output)
  | _ -> usage ()
