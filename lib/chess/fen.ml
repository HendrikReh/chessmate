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

type t = string

let ( let* ) t f = Or_error.bind t ~f

let piece_chars =
  Set.of_list
    (module Char)
    [ 'p'; 'r'; 'n'; 'b'; 'q'; 'k'; 'P'; 'R'; 'N'; 'B'; 'Q'; 'K' ]

let is_piece_char ch = Set.mem piece_chars ch

type piece_counts = {
  mutable white_king : int;
  mutable black_king : int;
  mutable white_pawns : int;
  mutable black_pawns : int;
}

let init_counts () =
  { white_king = 0; black_king = 0; white_pawns = 0; black_pawns = 0 }

let char_digit_value ch =
  if Char.is_digit ch then Char.to_int ch - Char.to_int '0' else -1

let validate_rank counts ~rank_index rank =
  String.fold rank ~init:(Or_error.return 0) ~f:(fun acc ch ->
      Or_error.bind acc ~f:(fun total ->
          if Char.equal ch '/' then
            Or_error.error_string "unexpected '/' inside rank"
          else if Char.is_digit ch then
            let value = char_digit_value ch in
            if value <= 0 || value > 8 then
              Or_error.errorf "rank %d contains invalid digit '%c'"
                (rank_index + 1) ch
            else Or_error.return (total + value)
          else if is_piece_char ch then
            match ch with
            | 'K' ->
                counts.white_king <- counts.white_king + 1;
                Or_error.return (total + 1)
            | 'k' ->
                counts.black_king <- counts.black_king + 1;
                Or_error.return (total + 1)
            | 'P' ->
                if rank_index = 0 || rank_index = 7 then
                  Or_error.errorf
                    "rank %d contains a white pawn on an invalid rank"
                    (rank_index + 1)
                else (
                  counts.white_pawns <- counts.white_pawns + 1;
                  Or_error.return (total + 1))
            | 'p' ->
                if rank_index = 0 || rank_index = 7 then
                  Or_error.errorf
                    "rank %d contains a black pawn on an invalid rank"
                    (rank_index + 1)
                else (
                  counts.black_pawns <- counts.black_pawns + 1;
                  Or_error.return (total + 1))
            | _ -> Or_error.return (total + 1)
          else
            Or_error.errorf "rank %d contains invalid character '%c'"
              (rank_index + 1) ch))
  |> Or_error.bind ~f:(fun total ->
         if Int.equal total 8 then Or_error.return ()
         else
           Or_error.errorf "rank %d describes %d squares (expected 8)"
             (rank_index + 1) total)

let validate_piece_placement placement =
  let ranks = String.split placement ~on:'/' in
  match ranks with
  | ranks when List.length ranks <> 8 ->
      Or_error.error_string "piece placement must have 8 ranks"
  | _ -> (
      let counts = init_counts () in
      match
        List.foldi ranks ~init:(Or_error.return ()) ~f:(fun idx acc rank ->
            Or_error.bind acc ~f:(fun () ->
                validate_rank counts ~rank_index:idx rank))
      with
      | Error err -> Error err
      | Ok () ->
          if counts.white_king <> 1 || counts.black_king <> 1 then
            Or_error.error_string
              "FEN must contain exactly one white king and one black king"
          else if counts.white_pawns > 8 || counts.black_pawns > 8 then
            Or_error.error_string
              "FEN cannot contain more than eight pawns per side"
          else Ok ())

let validate_active_color = function
  | ("w" | "b") as color -> Or_error.return color
  | color -> Or_error.errorf "invalid active color '%s'" color

let normalize_castling castling =
  if String.equal castling "-" then Or_error.return "-"
  else
    let allowed = Set.of_list (module Char) [ 'K'; 'Q'; 'k'; 'q' ] in
    let chars = String.to_list castling in
    if List.exists chars ~f:(fun ch -> not (Set.mem allowed ch)) then
      Or_error.errorf "invalid castling availability '%s'" castling
    else
      let unique = Set.of_list (module Char) chars in
      if not (Int.equal (Set.length unique) (List.length chars)) then
        Or_error.errorf "castling availability '%s' contains duplicates"
          castling
      else
        let order = [ 'K'; 'Q'; 'k'; 'q' ] in
        let ordered = List.filter order ~f:(fun ch -> Set.mem unique ch) in
        match ordered with
        | [] ->
            Or_error.error_string
              "castling availability must be '-' when no rights remain"
        | _ -> Or_error.return (String.of_char_list ordered)

let validate_en_passant active_color square =
  if String.equal square "-" then Or_error.return "-"
  else if String.length square <> 2 then
    Or_error.errorf "invalid en passant square '%s'" square
  else
    let file = square.[0] |> Char.lowercase in
    let rank = square.[1] in
    let file_ok = Char.(file >= 'a' && file <= 'h') in
    let expected_rank = if String.equal active_color "w" then '6' else '3' in
    let rank_ok = Char.equal rank expected_rank in
    if not file_ok then
      Or_error.errorf "en passant file '%c' is invalid" square.[0]
    else if not (Char.is_digit rank) then
      Or_error.errorf "en passant rank '%c' is invalid" rank
    else if not rank_ok then
      Or_error.errorf "en passant square '%s' inconsistent with active color"
        square
    else Or_error.return (String.of_char file ^ String.of_char rank)

let parse_non_negative_int field name =
  match Int.of_string field with
  | value when value >= 0 -> Or_error.return value
  | _ -> Or_error.errorf "%s must be non-negative" name
  | exception _ -> Or_error.errorf "%s must be an integer" name

let parse_positive_int field name =
  match Int.of_string field with
  | value when value >= 1 -> Or_error.return value
  | _ -> Or_error.errorf "%s must be >= 1" name
  | exception _ -> Or_error.errorf "%s must be an integer" name

let normalize fen =
  let trimmed = String.strip fen in
  if String.is_empty trimmed then Or_error.error_string "FEN must be non-empty"
  else
    let parts =
      trimmed |> String.split ~on:' ' |> List.filter ~f:(Fn.non String.is_empty)
    in
    match parts with
    | [ placement; active; castling; en_passant; halfmove; fullmove ] ->
        let* () = validate_piece_placement placement in
        let* active = validate_active_color active in
        let* castling = normalize_castling castling in
        let* en_passant = validate_en_passant active en_passant in
        let* _halfmove = parse_non_negative_int halfmove "halfmove clock" in
        let* _fullmove = parse_positive_int fullmove "fullmove number" in
        Or_error.return
          (String.concat ~sep:" "
             [ placement; active; castling; en_passant; halfmove; fullmove ])
    | _ ->
        Or_error.error_string
          "FEN must consist of exactly six space-separated fields"

let hash fen = Stdlib.Digest.(string fen |> to_hex)
