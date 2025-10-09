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

type rating_filter = {
  white_min : int option;
  black_min : int option;
  max_rating_delta : int option;
}

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

let default_limit = 5

let stopwords =
  let words =
    [ "a"; "an"; "and"; "any"; "attack"; "at"; "be"; "between"; "by"; "can"; "find"
    ; "for"; "games"; "game"; "give"; "how"; "i"; "in"; "is"; "list"; "me"; "more"
    ; "of"; "on"; "over"; "please"; "points"; "return"; "show"; "than"; "that"; "the"
    ; "those"; "to"; "with"; "would"; "where"; "which"; "about"; "looking"; "need"
    ; "who"; "wins"; "win"; "players"; "player"; "rated"; "rating"; "elo"; "elo"; "lower"
    ; "higher"; "at"; "least"; "most"; "top"; "best"; "favourite"; "favorite" ]
  in
  Set.of_list (module String) words

let normalize text =
  let buffer = Buffer.create (String.length text) in
  String.iter text ~f:(fun ch ->
      if Char.is_alphanum ch then Buffer.add_char buffer (Char.lowercase ch)
      else if Char.equal ch '\'' then ()
      else if Char.is_whitespace ch then Buffer.add_char buffer ' '
      else Buffer.add_char buffer ' ');
  Buffer.contents buffer |> String.strip

let tokenize text =
  String.split text ~on:' '
  |> List.filter ~f:(fun token -> not (String.is_empty token))

let int_of_token token =
  if String.is_empty token then None
  else if String.for_all token ~f:Char.is_digit then
    (try Some (Int.of_string token) with
    | Failure _ -> None)
  else
    let mapping =
      [ "one", 1; "two", 2; "three", 3; "four", 4; "five", 5; "six", 6; "seven", 7
      ; "eight", 8; "nine", 9; "ten", 10; "eleven", 11; "twelve", 12; "thirteen", 13
      ; "fourteen", 14; "fifteen", 15; "sixteen", 16; "seventeen", 17; "eighteen", 18
      ; "nineteen", 19; "twenty", 20; "thirty", 30; "forty", 40; "fifty", 50; "hundred", 100 ]
    in
    List.Assoc.find mapping ~equal:String.equal token

let limit_from_tokens tokens =
  let qualifier_words =
    Set.of_list (module String) [ "top"; "first"; "show"; "list"; "give"; "find"; "return" ]
  in
  let rec loop tokens prev_token =
    match tokens with
    | [] -> None
    | token :: rest ->
        let next_token = match rest with | next :: _ -> Some next | [] -> None in
        (match int_of_token token with
        | Some value when value > 0 && value <= 50 ->
            let qualifies =
              Option.value_map prev_token ~default:false ~f:(fun prev -> Set.mem qualifier_words prev)
              || Option.value_map next_token ~default:false ~f:(fun next -> String.equal next "games" || String.equal next "game")
            in
            if qualifies then Some value else loop rest (Some token)
        | _ -> loop rest (Some token))
  in
  loop tokens None

let dedup_filters filters =
  let compare_filter a b =
    match String.compare a.field b.field with
    | 0 -> String.compare a.value b.value
    | cmp -> cmp
  in
  filters
  |> List.sort ~compare:compare_filter
  |> List.fold ~init:[] ~f:(fun acc filter ->
         match acc with
         | last :: _ when compare_filter last filter = 0 -> acc
         | _ -> filter :: acc)
  |> List.rev

let metadata_from_phrases cleaned =
  let manual =
    [ ([ "endgame"; "end game" ], { field = "phase"; value = "endgame" })
    ; ([ "middle game"; "middlegame" ], { field = "phase"; value = "middlegame" })
    ; ([ "queenside majority"; "queenside pawn majority" ], { field = "theme"; value = "queenside_majority" })
    ; ([ "sacrifice"; "sacrifices" ], { field = "theme"; value = "sacrifice" })
    ; ([ "tactical"; "tactics" ], { field = "theme"; value = "tactics" })
    ; ([ "attacking the king"; "king attack" ], { field = "theme"; value = "king_attack" })
    ]
  in
  let manual_filters =
    manual
    |> List.filter_map ~f:(fun (variants, filter) ->
           if List.exists variants ~f:(fun phrase -> String.is_substring cleaned ~substring:phrase) then Some filter else None)
  in
  let opening_filters =
    Openings.filters_for_text cleaned
    |> List.map ~f:(fun (field, value) -> { field; value })
  in
  dedup_filters (manual_filters @ opening_filters)

let result_filters cleaned =
  let result = ref [] in
  if String.is_substring cleaned ~substring:"white win" || String.is_substring cleaned ~substring:"white victory"
  then result := { field = "result"; value = "1-0" } :: !result;
  if String.is_substring cleaned ~substring:"black win" || String.is_substring cleaned ~substring:"black victory"
  then result := { field = "result"; value = "0-1" } :: !result;
  if String.is_substring cleaned ~substring:"draw" || String.is_substring cleaned ~substring:"drawn"
  then result := { field = "result"; value = "1/2-1/2" } :: !result;
  dedup_filters !result

let extract_keywords tokens =
  let rec loop tokens seen acc =
    match tokens with
    | [] -> List.rev acc
    | token :: rest ->
        if Set.mem stopwords token || String.length token <= 2 then loop rest seen acc
        else if Set.mem seen token then loop rest seen acc
        else loop rest (Set.add seen token) (token :: acc)
  in
  loop tokens (Set.empty (module String)) []

let parse_rating tokens =
  let module State = struct
    type t = {
      rating : rating_filter;
      current_color : [ `White | `Black ] option;
      pending_number : int option;
      previous_tokens : string list;
    }

    let empty =
      { rating = { white_min = None; black_min = None; max_rating_delta = None }
      ; current_color = None
      ; pending_number = None
      ; previous_tokens = [] }
  end
  in
  let relevant_context token =
    String.equal token "points"
    || String.equal token "elo"
    || String.equal token "rating"
    || String.equal token "ratings"
    || String.equal token "rated"
  in
  let update_rating rating color value =
    match color with
    | Some `White ->
        let updated =
          match rating.white_min with
          | None -> Some value
          | Some existing -> Some (Int.max existing value)
        in
        { rating with white_min = updated }
    | Some `Black ->
        let updated =
          match rating.black_min with
          | None -> Some value
          | Some existing -> Some (Int.max existing value)
        in
        { rating with black_min = updated }
    | None -> rating
  in
  let difference_words =
    Set.of_list (module String) [ "lower"; "less"; "higher"; "greater"; "more"; "fewer" ]
  in
  let min_context_words =
    Set.of_list (module String) [ "least"; "minimum"; "min"; "over"; "above"; "atleast"; "at_least"; ">=" ]
  in
  let update_previous previous token =
    let trimmed = List.take previous 4 in
    token :: trimmed
  in
  let rec loop tokens state =
    match tokens with
    | [] -> state.State.rating
    | token :: rest ->
        let color =
          if String.equal token "white" then Some `White
          else if String.equal token "black" then Some `Black
          else state.State.current_color
        in
        let previous_tokens = update_previous state.State.previous_tokens token in
        (match int_of_token token with
        | Some value ->
            let diff_context =
              List.take rest 3
              |> List.exists ~f:(fun next -> Set.mem difference_words next)
            in
            let min_context =
              List.exists state.State.previous_tokens ~f:(fun prev -> Set.mem min_context_words prev)
            in
            let rating =
              if diff_context then state.State.rating
              else if min_context then update_rating state.State.rating color value
              else state.State.rating
            in
            loop rest State.{ rating; current_color = color; pending_number = Some value; previous_tokens }
        | None ->
            let rating =
              match token, state.State.pending_number with
              | ("lower" | "less"), Some value -> { state.State.rating with max_rating_delta = Some value }
              | _ -> state.State.rating
            in
            let pending_number =
              if relevant_context token then state.State.pending_number else None
            in
            loop rest State.{ rating; current_color = color; pending_number; previous_tokens })
  in
  loop tokens State.empty

let analyse request =
  let cleaned_text = normalize request.text in
  let tokens = tokenize cleaned_text in
  let limit = Option.value (limit_from_tokens tokens) ~default:default_limit in
  let filters =
    let metadata = metadata_from_phrases cleaned_text in
    let result = result_filters cleaned_text in
    dedup_filters (metadata @ result)
  in
  let keywords = extract_keywords tokens in
  let rating = parse_rating tokens in
  { original = request; cleaned_text; keywords; filters; rating; limit }
