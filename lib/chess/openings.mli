(** Maps ECO codes to canonical openings and synonyms for intent detection. *)

open! Base

(** Canonical opening metadata backed by ECO ranges. *)

type entry

val all : entry list
(** Entire opening catalogue. *)

val canonical_name_of_eco : string -> string option
(** [canonical_name_of_eco eco] resolves [eco] (e.g. "E60") to a canonical
    opening name if the ECO code is covered by the catalogue. *)

val slug_of_eco : string -> string option
(** Slug (lowercase, underscore) for the [eco] family. *)

val slugify : string -> string
(** Slugify an opening name for storage/filtering. *)

val filters_for_text : string -> (string * string) list
(** Build metadata filters for the given lowercased, punctuation-stripped text.
*)
