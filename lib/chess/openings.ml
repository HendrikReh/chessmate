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

let slugify name =
  let lower = String.lowercase name in
  let buffer = Buffer.create (String.length lower) in
  let pending_separator = ref false in
  String.iter lower ~f:(fun ch ->
      if Char.is_alphanum ch then (
        if !pending_separator && Buffer.length buffer > 0 then Buffer.add_char buffer '_';
        Buffer.add_char buffer ch;
        pending_separator := false)
      else if Char.equal ch '\'' then ()
      else pending_separator := true);
  Buffer.contents buffer

let sanitize_phrase phrase =
  let lower = String.lowercase phrase in
  let buffer = Buffer.create (String.length lower) in
  String.iter lower ~f:(fun ch ->
      if Char.is_alphanum ch then Buffer.add_char buffer ch
      else if Char.is_whitespace ch then Buffer.add_char buffer ' ');
  Buffer.contents buffer |> String.strip

let eco_compare a b = String.compare a b

let eco_in_range ~eco ~start_code ~end_code =
  eco_compare eco start_code >= 0 && eco_compare eco end_code <= 0

let eco_range_string ~start_code ~end_code =
  if String.equal start_code end_code then start_code else start_code ^ "-" ^ end_code

let normalize_eco eco = String.uppercase (String.strip eco)

type entry = {
  eco_start : string;
  eco_end : string;
  canonical : string;
  slug : string;
  synonyms : string list;
}

let make_entry ~start_code ~end_code ~canonical ~synonyms =
  let eco_start = normalize_eco start_code in
  let eco_end = normalize_eco end_code in
  let slug = slugify canonical in
  let normalized_synonyms =
    synonyms
    |> List.map ~f:sanitize_phrase
    |> List.filter ~f:(fun s -> not (String.is_empty s))
  in
  { eco_start; eco_end; canonical; slug; synonyms = normalized_synonyms }

let all : entry list =
  [ make_entry
      ~start_code:"E60"
      ~end_code:"E99"
      ~canonical:"King's Indian Defense"
      ~synonyms:[ "king's indian"; "kings indian"; "kings indian defense"; "kings indian defence" ];
    make_entry
      ~start_code:"B20"
      ~end_code:"B99"
      ~canonical:"Sicilian Defense"
      ~synonyms:[ "sicilian"; "sicilian defence"; "sicilian defense"; "sicilian najdorf"; "najdorf" ];
    make_entry
      ~start_code:"C00"
      ~end_code:"C19"
      ~canonical:"French Defense"
      ~synonyms:[ "french defense"; "french defence"; "french" ];
    make_entry
      ~start_code:"B10"
      ~end_code:"B19"
      ~canonical:"Caro-Kann Defense"
      ~synonyms:[ "caro kann"; "caro-kann"; "carokann" ];
    make_entry
      ~start_code:"D06"
      ~end_code:"D69"
      ~canonical:"Queen's Gambit"
      ~synonyms:[ "queen's gambit"; "queens gambit"; "queens-gambit" ];
    make_entry
      ~start_code:"C60"
      ~end_code:"C99"
      ~canonical:"Ruy Lopez"
      ~synonyms:[ "ruy lopez"; "spanish"; "spanish game" ];
    make_entry
      ~start_code:"E20"
      ~end_code:"E59"
      ~canonical:"Nimzo-Indian Defense"
      ~synonyms:[ "nimzo indian"; "nimzo-indian"; "nimzo" ];
    make_entry
      ~start_code:"E12"
      ~end_code:"E19"
      ~canonical:"Queen's Indian Defense"
      ~synonyms:[ "queen's indian"; "queens indian"; "queens-indian" ];
    make_entry
      ~start_code:"A10"
      ~end_code:"A39"
      ~canonical:"English Opening"
      ~synonyms:[ "english opening"; "english" ];
    make_entry
      ~start_code:"A80"
      ~end_code:"A99"
      ~canonical:"Dutch Defense"
      ~synonyms:[ "dutch defense"; "dutch defence"; "dutch" ];
    make_entry
      ~start_code:"B01"
      ~end_code:"B02"
      ~canonical:"Scandinavian Defense"
      ~synonyms:[ "scandinavian"; "scandinavian defense"; "scandinavian defence"; "center counter"; "centre counter" ];
    make_entry
      ~start_code:"D70"
      ~end_code:"D99"
      ~canonical:"Grunfeld Defense"
      ~synonyms:[ "grunfeld"; "grünfeld"; "grunfeld defense"; "grunfeld defence" ];
  ]

let canonical_name_of_eco eco =
  let eco = normalize_eco eco in
  List.find_map all ~f:(fun entry ->
      if eco_in_range ~eco ~start_code:entry.eco_start ~end_code:entry.eco_end then Some entry.canonical
      else None)

let slug_of_eco eco =
  let eco = normalize_eco eco in
  List.find_map all ~f:(fun entry ->
      if eco_in_range ~eco ~start_code:entry.eco_start ~end_code:entry.eco_end then Some entry.slug else None)

let filters_for_text cleaned_text =
  let matches =
    all
    |> List.filter ~f:(fun entry ->
           List.exists entry.synonyms ~f:(fun synonym ->
               String.is_substring cleaned_text ~substring:synonym))
  in
  let filters =
    matches
    |> List.concat_map ~f:(fun entry ->
           [ ("opening", entry.slug)
           ; ("eco_range", eco_range_string ~start_code:entry.eco_start ~end_code:entry.eco_end) ])
  in
  filters
  |> List.dedup_and_sort ~compare:(fun (fa, va) (fb, vb) ->
         match String.compare fa fb with
         | 0 -> String.compare va vb
         | cmp -> cmp)
