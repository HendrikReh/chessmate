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

(** Query embedding provider returning OpenAI vectors when configured and a
    deterministic fallback otherwise. *)

type source = Embedding_service | Deterministic_fallback

type fetch_result = {
  vector : float list;
  source : source;
  warnings : string list;
}

type t

val current : unit -> t
(** Resolve the active provider, initialising it from environment variables on
    first use. Subsequent calls reuse the cached provider unless overridden via
    {!For_tests.with_provider}. *)

val fetch : t -> Query_intent.plan -> fetch_result
(** Produce a query vector for [plan], sourcing real embeddings when available
    and falling back to a deterministic hash-based vector otherwise. *)

val deterministic_vector : Query_intent.plan -> float list
(** Deterministic hash-based vector used as a fallback when embeddings are
    unavailable. Exposed for testing. *)

val reset : unit -> unit
(** Clear the cached provider so that the next {!current} call re-reads
    configuration. Mainly useful for integration tests that mutate env vars. *)

(** Helpers for injecting deterministic providers in unit tests. *)
module For_tests : sig
  val make_disabled : reason:string -> t
  val make_enabled : embed:(string -> float array list Or_error.t) -> t
  val with_provider : t -> (unit -> 'a) -> 'a
end
