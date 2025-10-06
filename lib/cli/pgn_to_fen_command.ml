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

(* Writes each FEN on its own line to the provided channel. *)
let write_fens channel fens =
  List.iter fens ~f:(fun fen -> Out_channel.output_string channel fen; Out_channel.newline channel)

let run ~input ~output =
  match Pgn_to_fen.fens_of_file input with
  | Error _ as err -> err
  | Ok fens ->
      (match output with
      | None -> write_fens Out_channel.stdout fens
      | Some path -> Out_channel.with_file path ~f:(fun oc -> write_fens oc fens));
      Or_error.return ()
