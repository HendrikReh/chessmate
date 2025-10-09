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

type status =
  | Pending
  | In_progress
  | Completed
  | Failed

let status_to_string = function
  | Pending -> "pending"
  | In_progress -> "in_progress"
  | Completed -> "completed"
  | Failed -> "failed"

let status_of_string = function
  | "pending" -> Or_error.return Pending
  | "in_progress" -> Or_error.return In_progress
  | "completed" -> Or_error.return Completed
  | "failed" -> Or_error.return Failed
  | other -> Or_error.errorf "Unknown job status: %s" other

type t = {
  id : int;
  fen : string;
  attempts : int;
  status : status;
  last_error : string option;
}

let create_pending ~id ~fen =
  { id; fen; attempts = 0; status = Pending; last_error = None }

let mark_started job =
  { job with status = In_progress; attempts = job.attempts + 1; last_error = None }

let mark_completed job = { job with status = Completed }

let mark_failed job ~error = { job with status = Failed; last_error = Some error }
