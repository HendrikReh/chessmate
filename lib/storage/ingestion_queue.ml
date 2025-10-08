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

(* Helpers for reading and updating the embedding job queue in Postgres. *)

open! Base

type job = {
  fen : string;
  metadata : (string * string) list;
}

type t = job Queue.t

let create () = Queue.create ()

let enqueue t job =
  Queue.enqueue t job;
  Ok ()

let dequeue_batch t limit =
  if limit <= 0 then Or_error.error_string "limit must be positive"
  else
    let rec loop acc remaining =
      if remaining = 0 || Queue.is_empty t then List.rev acc
      else
        let next = Queue.dequeue_exn t in
        loop (next :: acc) (remaining - 1)
    in
    Ok (loop [] limit)
