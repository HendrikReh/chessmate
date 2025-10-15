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
    with an operator note.
    @param log_path
      Override the log destination (defaults to
      `snapshots/qdrant_snapshots.jsonl` or the [CHESSMATE_SNAPSHOT_LOG]
      environment variable).
    @param note Free-form annotation stored alongside the snapshot metadata.
    @param snapshot_name
      Optional label passed to Qdrant; the server generates a timestamped name
      when omitted. *)

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
(** Print snapshots reported by Qdrant as well as locally recorded metadata.
    @param log_path Alternate metadata log location to read from. *)
