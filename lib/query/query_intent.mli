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

(** Translate natural-language questions into structured filters that the hybrid
    planner can execute. The intent analysis is deliberately deterministic—no
    LLM involvement—so behaviour is stable and easy to test. *)

type rating_filter = {
  white_min : int option;
  black_min : int option;
  max_rating_delta : int option;
}
(** Rating constraints extracted from phrases such as "white 2700", "players
    within 100 points", etc. [None] means the user did not request that bound.
*)

(** Metadata filter aligned with payload fields stored in Postgres/Qdrant. *)
type metadata_filter = { field : string; value : string }
(** Each filter is a concrete predicate the storage layer understands—for
    example [{ field = "opening"; value = "kings_indian_defense" }]. *)

type request = { text : string }
(** Raw user input. The planner currently accepts only the free-text field. *)

type plan = {
  original : request;
  cleaned_text : string;
  keywords : string list;
  filters : metadata_filter list;
  rating : rating_filter;
  limit : int;
}
(** Parsed representation of a question. [cleaned_text] lowercases and removes
    punctuation; [keywords] drives fallback scoring; [filters]/[rating] feed SQL
    and vector payload predicates; [limit] caps the number of results. *)

val default_limit : int
(** Default result cap when the user does not specify one (currently 50). *)

val analyse : request -> plan
(** [analyse request] normalises the question, extracts openings/ECO ranges,
    rating bounds, keywords, and an optional limit. The output feeds the hybrid
    planner and ultimately the API response. *)
