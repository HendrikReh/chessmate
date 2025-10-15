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

val snapshot :
  ?log_path:string ->
  ?note:string ->
  ?snapshot_name:string ->
  unit ->
  unit Or_error.t
(** Perform a Qdrant collection snapshot, optionally annotating the metadata log
    with an operator note. When [snapshot_name] is [None], Qdrant generates a
    timestamped name. [log_path] overrides the default
    `snapshots/qdrant_snapshots.jsonl` or [CHESSMATE_SNAPSHOT_LOG]. *)

val restore :
  ?log_path:string ->
  ?snapshot_name:string ->
  ?location:string ->
  unit ->
  unit Or_error.t
(** Restore the collection from either an explicit filesystem [location] or the
    latest entry in the metadata log matching [snapshot_name]. One of
    [snapshot_name] or [location] must be supplied. *)

val list : ?log_path:string -> unit -> unit Or_error.t
(** Print snapshots reported by Qdrant as well as locally recorded metadata. *)
