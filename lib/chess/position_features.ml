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

(* Derives high-level features (phase, pawn structure, etc.) from board states. *)

open! Base

type theme =
  | Unknown
  | KingsideAttack
  | QueensideMajority
  | CentralBreak

let theme_of_tags tags =
  let downcased = List.map tags ~f:String.lowercase in
  if List.exists downcased ~f:(String.is_substring ~substring:"queenside majority") then
    QueensideMajority
  else if List.exists downcased ~f:(String.is_substring ~substring:"kingside attack") then
    KingsideAttack
  else if List.exists downcased ~f:(String.is_substring ~substring:"central break") then
    CentralBreak
  else
    Unknown

let to_payload_fragments = function
  | Unknown -> [ "theme", "unknown" ]
  | KingsideAttack -> [ "theme", "kingside_attack" ]
  | QueensideMajority -> [ "theme", "queenside_majority" ]
  | CentralBreak -> [ "theme", "central_break" ]
