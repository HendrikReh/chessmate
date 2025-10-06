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

(** Status of an embedding job. *)
type status =
  | Pending
  | In_progress
  | Completed
  | Failed

val status_to_string : status -> string
val status_of_string : string -> status Or_error.t

(** Representation of a job fetched from the database. *)
type t = {
  id : int;
  fen : string;
  attempts : int;
  status : status;
  last_error : string option;
}

val create_pending : id:int -> fen:string -> t
val mark_started : t -> t
val mark_completed : t -> t
val mark_failed : t -> error:string -> t
