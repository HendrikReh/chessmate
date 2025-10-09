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

(** Wraps the OpenAI embeddings API for batch FEN requests. *)

open! Base

type t

val create : api_key:string -> endpoint:string -> t Or_error.t
val embed_fens : t -> string list -> float array list Or_error.t
(** Batch request embeddings for FEN strings using the OpenAI embeddings REST API.

    Requests automatically retry on transient HTTP failures (429, 5xx, etc.)
    using exponential backoff. Configure retry behaviour via the optional
    environment variables [OPENAI_RETRY_MAX_ATTEMPTS] and
    [OPENAI_RETRY_BASE_DELAY_MS]. *)
