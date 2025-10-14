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

val create : ?prefix:string -> ?suffix:string -> unit -> string Or_error.t
(** [create ()] returns the path to a newly created temporary file located in
    [Filename.temp_dir_name]. The file is registered for automatic cleanup on
    process exit or shutdown signals. *)

val register : string -> unit Or_error.t
(** Register an existing temporary file for cleanup. *)

val remove : string -> unit
(** Remove (best-effort) a previously registered file and drop it from the
    cleanup set. It is not an error if the file is already missing. *)

val cleanup_now : unit -> unit
(** Force an immediate cleanup of all registered files. Intended for tests. *)
