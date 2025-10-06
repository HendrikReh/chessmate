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

(** Translate natural-language questions into structured filters. *)

type rating_filter = {
  white_min : int option;
  black_min : int option;
  max_rating_delta : int option;
}

(** Metadata filter aligned with payload fields stored in Postgres/Qdrant. *)
type metadata_filter = {
  field : string;
  value : string;
}

type request = {
  text : string;
}

type plan = {
  original : request;
  cleaned_text : string;
  keywords : string list;
  filters : metadata_filter list;
  rating : rating_filter;
  limit : int;
}

val default_limit : int

val analyse : request -> plan
