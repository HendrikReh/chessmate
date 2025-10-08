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

(* Structures and normalizes PGN header information. *)

open! Base

type player = {
  name : string;
  fide_id : string option;
  rating : int option;
}

let empty_player = { name = ""; fide_id = None; rating = None }

type t = {
  event : string option;
  site : string option;
  date : string option;
  round : string option;
  white : player;
  black : player;
  eco_code : string option;
  opening_name : string option;
  opening_slug : string option;
  result : string option;
}

let empty =
  {
    event = None;
    site = None;
    date = None;
    round = None;
    white = empty_player;
    black = empty_player;
    eco_code = None;
    opening_name = None;
    opening_slug = None;
    result = None;
  }

let find_header headers key = List.Assoc.find headers ~equal:String.equal key

let parse_int_opt value =
  Option.bind value ~f:(fun s -> Int.of_string_opt (String.strip s))

let normalize_date value =
  match value with
  | None -> None
  | Some raw ->
      let trimmed = String.strip raw in
      if String.is_empty trimmed then None
      else
        match String.split trimmed ~on:'.' with
        | [yyyy; mm; dd] ->
            if String.exists yyyy ~f:(Char.equal '?') then None
            else
              let fix part default_value =
                if String.exists part ~f:(Char.equal '?') then default_value else part
              in
              let mm = fix mm "01" in
              let dd = fix dd "01" in
              Some (String.concat ~sep:"-" [ yyyy; mm; dd ])
        | _ -> Some trimmed

let sanitize_string value =
  match value with
  | None -> None
  | Some s ->
      let trimmed = String.strip s in
      if String.is_empty trimmed then None else Some trimmed

let player_from_headers headers color_key elo_key fide_key =
  let name = Option.value (sanitize_string (find_header headers color_key)) ~default:"" in
  let rating = parse_int_opt (find_header headers elo_key) in
  let fide_id = sanitize_string (find_header headers fide_key) in
  { name; rating; fide_id }

let of_headers headers =
  let event = sanitize_string (find_header headers "Event") in
  let site = sanitize_string (find_header headers "Site") in
  let date = normalize_date (find_header headers "Date") in
  let round = sanitize_string (find_header headers "Round") in
  let eco_code = sanitize_string (find_header headers "ECO") in
  let opening_header = sanitize_string (find_header headers "Opening") in
  let canonical_from_eco = Option.bind eco_code ~f:Openings.canonical_name_of_eco in
  let opening_name =
    match opening_header, canonical_from_eco with
    | Some name, _ -> Some name
    | None, Some canonical -> Some canonical
    | None, None -> None
  in
  let opening_slug =
    match opening_name with
    | Some name -> Some (Openings.slugify name)
    | None -> Option.bind eco_code ~f:Openings.slug_of_eco
  in
  let result = sanitize_string (find_header headers "Result") in
  let white = player_from_headers headers "White" "WhiteElo" "WhiteFideId" in
  let black = player_from_headers headers "Black" "BlackElo" "BlackFideId" in
  { event; site; date; round; white; black; eco_code; opening_name; opening_slug; result }
