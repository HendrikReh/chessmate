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

(** Convert SAN move sequences into incremental FEN snapshots used by ingestion,
    embedding, and downstream analytics. *)

open! Base

module Color = struct
  type t = White | Black

  let equal a b =
    match a, b with
    | White, White | Black, Black -> true
    | _ -> false

  let opposite = function
    | White -> Black
    | Black -> White

  let to_fen = function
    | White -> "w"
    | Black -> "b"
end

module Piece_kind = struct
  type t = Pawn | Knight | Bishop | Rook | Queen | King

  let equal (a : t) (b : t) = phys_equal a b
end

module Piece = struct
  type t = { color : Color.t; kind : Piece_kind.t }
end

module Square = struct
  type t = int * int [@@deriving compare]

  let to_string (file, rank) =
    let file_char = Stdlib.Char.chr (Stdlib.Char.code 'a' + file) in
    let rank_char = Stdlib.Char.chr (Stdlib.Char.code '1' + rank) in
    String.of_char_list [ file_char; rank_char ]

  let on_board (file, rank) = file >= 0 && file < 8 && rank >= 0 && rank < 8
end

module Board = struct
  type t = Piece.t option array array

  let create () = Array.make_matrix ~dimx:8 ~dimy:8 None

  let get t (file, rank) = if Square.on_board (file, rank) then t.(rank).(file) else None

  let set t (file, rank) piece = t.(rank).(file) <- piece

  let move t ~src ~dst =
    let captured = get t dst in
    set t dst (get t src);
    set t src None;
    captured
end

module Castling = struct
  type t =
    { mutable white_king_side : bool
    ; mutable white_queen_side : bool
    ; mutable black_king_side : bool
    ; mutable black_queen_side : bool
    }

  let initial () =
    { white_king_side = true
    ; white_queen_side = true
    ; black_king_side = true
    ; black_queen_side = true
    }

  let to_fen t =
    let buf = Buffer.create 4 in
    if t.white_king_side then Buffer.add_char buf 'K';
    if t.white_queen_side then Buffer.add_char buf 'Q';
    if t.black_king_side then Buffer.add_char buf 'k';
    if t.black_queen_side then Buffer.add_char buf 'q';
    match Buffer.contents buf with
    | "" -> "-"
    | s -> s
end

module State = struct
  type t =
    { board : Board.t
    ; castling : Castling.t
    ; mutable to_move : Color.t
    ; mutable en_passant : Square.t option
    ; mutable halfmove_clock : int
    ; mutable fullmove_number : int
    }

  let initial () =
    let board = Board.create () in
    let place_back_rank color rank =
      let open Piece_kind in
      let file_to_piece =
        [| Rook; Knight; Bishop; Queen; King; Bishop; Knight; Rook |]
      in
      for file = 0 to 7 do
        Board.set board (file, rank) (Some Piece.{ color; kind = file_to_piece.(file) })
      done
    in
    for file = 0 to 7 do
      Board.set board (file, 1) (Some Piece.{ color = Color.White; kind = Piece_kind.Pawn });
      Board.set board (file, 6) (Some Piece.{ color = Color.Black; kind = Piece_kind.Pawn })
    done;
    place_back_rank Color.White 0;
    place_back_rank Color.Black 7;
    { board
    ; castling = Castling.initial ()
    ; to_move = Color.White
    ; en_passant = None
    ; halfmove_clock = 0
    ; fullmove_number = 1
    }
end

module Fen = struct
  let piece_char (piece : Piece.t) =
    let base =
      match piece.kind with
      | Piece_kind.Pawn -> 'p'
      | Knight -> 'n'
      | Bishop -> 'b'
      | Rook -> 'r'
      | Queen -> 'q'
      | King -> 'k'
    in
    match piece.Piece.color with
    | Color.White -> Stdlib.Char.uppercase_ascii base
    | Color.Black -> base

  let placement board =
    let buf = Buffer.create 64 in
    for rank = 7 downto 0 do
      let empty = ref 0 in
      for file = 0 to 7 do
        match Board.get board (file, rank) with
        | None -> empty := !empty + 1
        | Some piece ->
          if !empty > 0 then begin
            Buffer.add_string buf (Int.to_string !empty);
            empty := 0
          end;
          Buffer.add_char buf (piece_char piece)
      done;
      if !empty > 0 then Buffer.add_string buf (Int.to_string !empty);
      if rank > 0 then Buffer.add_char buf '/'
    done;
    Buffer.contents buf

  let to_string (state : State.t) =
    String.concat ~sep:" "
      [ placement state.board
      ; Color.to_fen state.to_move
      ; Castling.to_fen state.castling
      ; (match state.en_passant with None -> "-" | Some sq -> Square.to_string sq)
      ; Int.to_string state.halfmove_clock
      ; Int.to_string state.fullmove_number
      ]
end

module San = struct
  type t =
    | Castle_kingside
    | Castle_queenside
    | Piece of
        { kind : Piece_kind.t
        ; disambig_file : int option
        ; disambig_rank : int option
        ; capture : bool
        ; destination : Square.t
        ; promotion : Piece_kind.t option
        }
    | Pawn of
        { from_file : int option
        ; capture : bool
        ; destination : Square.t
        ; promotion : Piece_kind.t option
        }

  let is_file c = Char.(c >= 'a' && c <= 'h')
  let is_rank c = Char.(c >= '1' && c <= '8')

  let file_of_char c = Char.to_int c - Char.to_int 'a'
  let rank_of_char c = Char.to_int c - Char.to_int '1'

  let promotion_kind = function
    | 'N' -> Some Piece_kind.Knight
    | 'B' -> Some Piece_kind.Bishop
    | 'R' -> Some Piece_kind.Rook
    | 'Q' -> Some Piece_kind.Queen
    | _ -> None

  let piece_kind_of_char = function
    | 'N' -> Piece_kind.Knight
    | 'B' -> Bishop
    | 'R' -> Rook
    | 'Q' -> Queen
    | 'K' -> King
    | _ -> failwith "invalid piece designator"

  let strip_suffixes token =
    let len = String.length token in
    let rec drop idx =
      if idx > 0 && ((Stdlib.Char.equal token.[idx - 1] '+') || (Stdlib.Char.equal token.[idx - 1] '#'))
      then drop (idx - 1)
      else idx
    in
    String.subo token ~pos:0 ~len:(drop len)

  let coords str =
    if String.length str <> 2 then failwith ("invalid square " ^ str);
    (file_of_char str.[0], rank_of_char str.[1])

  let parse token =
    let open Stdlib in
    let tok = strip_suffixes token in
    if tok = "O-O" || tok = "0-0" then Castle_kingside
    else if tok = "O-O-O" || tok = "0-0-0" then Castle_queenside
    else
      let promotion, body =
        try
          let eq = String.index tok '=' in
          promotion_kind tok.[eq + 1], String.sub tok 0 eq
        with Not_found -> None, tok
      in
      let body_len = String.length body in
      if body_len < 2 then failwith ("SAN too short: " ^ token);
      let dest = coords (String.sub body (body_len - 2) 2) in
      let first = body.[0] in
      if Stdlib.Char.uppercase_ascii first = first && not (is_file first) then begin
        let kind = piece_kind_of_char first in
        let core = String.sub body 1 (body_len - 3) in
        let dis_file = ref None in
        let dis_rank = ref None in
        let capture = Base.String.exists tok ~f:(fun c -> Stdlib.Char.equal c 'x') in
        String.iter
          (fun c ->
            if is_file c then dis_file := Some (file_of_char c)
            else if is_rank c then dis_rank := Some (rank_of_char c)
            else if Stdlib.(c = 'x') then ())
          core;
        Piece { kind; disambig_file = !dis_file; disambig_rank = !dis_rank; capture; destination = dest; promotion }
      end else begin
        let capture = Base.String.exists body ~f:(fun c -> Stdlib.Char.equal c 'x') in
        let from_file = if capture then Some (file_of_char body.[0]) else None in
        Pawn { from_file; capture; destination = dest; promotion }
      end
end

module Engine = struct
  let direction = function
    | Color.White -> 1
    | Color.Black -> -1

  let rook_king_src color = match color with Color.White -> (7, 0) | Color.Black -> (7, 7)
  let rook_queen_src color = match color with Color.White -> (0, 0) | Color.Black -> (0, 7)
  let home_rank color = match color with Color.White -> 1 | Color.Black -> 6

  let step delta = if delta = 0 then 0 else if delta > 0 then 1 else -1

  let path_clear board (sf, sr) (df, dr) =
    let file_step = step (df - sf) in
    let rank_step = step (dr - sr) in
    let rec loop (f, r) =
      let nf = f + file_step in
      let nr = r + rank_step in
      if nf = df && nr = dr then true
      else if not (Square.on_board (nf, nr)) then false
      else if Option.is_some (Board.get board (nf, nr)) then false
      else loop (nf, nr)
    in
    if sf = df && sr = dr then true else loop (sf, sr)

  let squares =
    List.init 8 ~f:(fun file -> List.init 8 ~f:(fun rank -> (file, rank))) |> List.concat

  let piece_matches board color kind square =
    match Board.get board square with
    | Some Piece.{ color = piece_color; kind = piece_kind }
      when Color.equal piece_color color && Piece_kind.equal piece_kind kind -> true
    | _ -> false

  let piece_can_move board kind src dst =
    let sf, sr = src in
    let df, dr = dst in
    match kind with
    | Piece_kind.Knight ->
      let df_abs = Int.abs (df - sf) in
      let dr_abs = Int.abs (dr - sr) in
      (df_abs = 1 && dr_abs = 2) || (df_abs = 2 && dr_abs = 1)
    | Bishop ->
      let df_abs = Int.abs (df - sf) in
      let dr_abs = Int.abs (dr - sr) in
      df_abs = dr_abs && path_clear board src dst
    | Rook ->
      (sf = df || sr = dr) && path_clear board src dst
    | Queen ->
      if sf = df || sr = dr then path_clear board src dst
      else
        let df_abs = Int.abs (df - sf) in
        let dr_abs = Int.abs (dr - sr) in
        df_abs = dr_abs && path_clear board src dst
    | King -> Int.abs (df - sf) <= 1 && Int.abs (dr - sr) <= 1
    | Pawn -> false

  let find_piece_sources board color kind destination dis_file dis_rank =
    List.filter squares ~f:(fun square ->
        piece_matches board color kind square
        && Option.for_all dis_file ~f:(fun file -> Int.equal file (fst square))
        && Option.for_all dis_rank ~f:(fun rank -> Int.equal rank (snd square))
        && piece_can_move board kind square destination)

  let update_castling_on_rook_move (state : State.t) color square =
    match color, square with
    | Color.White, (0, 0) -> state.castling.white_queen_side <- false
    | Color.White, (7, 0) -> state.castling.white_king_side <- false
    | Color.Black, (0, 7) -> state.castling.black_queen_side <- false
    | Color.Black, (7, 7) -> state.castling.black_king_side <- false
    | _ -> ()

  let update_castling_on_king_move (state : State.t) color =
    match color with
    | Color.White ->
      state.castling.white_king_side <- false;
      state.castling.white_queen_side <- false
    | Color.Black ->
      state.castling.black_king_side <- false;
      state.castling.black_queen_side <- false

  let remove_castling_rights_on_capture (state : State.t) = function
    | (0, 0) -> state.castling.white_queen_side <- false
    | (7, 0) -> state.castling.white_king_side <- false
    | (0, 7) -> state.castling.black_queen_side <- false
    | (7, 7) -> state.castling.black_king_side <- false
    | _ -> ()

  let advance_turn (state : State.t) =
    (match state.to_move with
     | Color.Black -> state.fullmove_number <- state.fullmove_number + 1
     | Color.White -> ());
    state.to_move <- Color.opposite state.to_move
end

let apply_castle state side =
  let rank = match state.State.to_move with Color.White -> 0 | Color.Black -> 7 in
  let king_src = (4, rank) in
  let king_dst, rook_src, rook_dst =
    match side with
    | `Kingside -> ((6, rank), Engine.rook_king_src state.to_move, (5, rank))
    | `Queenside -> ((2, rank), Engine.rook_queen_src state.to_move, (3, rank))
  in
  ignore (Board.move state.board ~src:king_src ~dst:king_dst);
  ignore (Board.move state.board ~src:rook_src ~dst:rook_dst);
  Engine.update_castling_on_king_move state state.to_move;
  state.en_passant <- None;
  state.halfmove_clock <- state.halfmove_clock + 1;
  Engine.advance_turn state;
  Or_error.return ()

let find_pawn_sources state color ~capture ~from_file destination =
  let board = state.State.board in
  let dir = Engine.direction color in
  let dest_file, dest_rank = destination in
  let candidate_files =
    match from_file with
    | Some f -> [ f ]
    | None -> if capture then [ dest_file - 1; dest_file + 1 ] else [ dest_file ]
  in
  let candidate_files = List.filter candidate_files ~f:(fun f -> f >= 0 && f < 8) in
  let dest_piece = Board.get board destination in
  let en_passant_target = state.en_passant in
  let home_rank = Engine.home_rank color in
  let square_has_pawn square =
    match Board.get board square with
    | Some Piece.{ color = piece_color; kind = piece_kind }
      when Color.equal piece_color color && Piece_kind.equal piece_kind Piece_kind.Pawn -> true
    | _ -> false
  in
  let one_step file = (file, dest_rank - dir) in
  let two_step file = (file, dest_rank - (2 * dir)) in
  List.filter_map candidate_files ~f:(fun file ->
      let one = one_step file in
      let two = two_step file in
      if capture then begin
        match dest_piece, en_passant_target with
        | (Some Piece.{ color = piece_color; _ }, _) when not (Color.equal piece_color color) ->
          if square_has_pawn one then Some one else None
        | (None, Some ep) when Poly.equal ep destination ->
          let captured_square = (dest_file, dest_rank - dir) in
          (match Board.get board captured_square with
           | Some Piece.{ color = piece_color; kind = piece_kind }
             when not (Color.equal piece_color color) && Piece_kind.equal piece_kind Piece_kind.Pawn ->
             if square_has_pawn one then Some one else None
           | _ -> None)
        | _ -> None
      end else begin
        match dest_piece with
        | Some _ -> None
        | None ->
          let res = ref [] in
          if Square.on_board one then begin
            match Board.get board one with
            | Some Piece.{ color = piece_color; kind = piece_kind }
              when Color.equal piece_color color && Piece_kind.equal piece_kind Piece_kind.Pawn ->
              res := one :: !res
            | _ -> ()
          end;
          if dest_rank = home_rank + (2 * dir) then begin
            match Board.get board one, Board.get board two with
            | None, Some Piece.{ color = piece_color; kind = piece_kind }
              when Color.equal piece_color color && Piece_kind.equal piece_kind Piece_kind.Pawn ->
              res := two :: !res
            | _ -> ()
          end;
          match !res with
          | [] -> None
          | src :: _ -> Some src
      end)

let apply_piece_move state ~kind ~dis_file ~dis_rank ~capture ~destination ~promotion =
  if Option.is_some promotion then Or_error.error_string "unexpected promotion on piece move"
  else
    Or_error.try_with (fun () ->
        let board = state.State.board in
        let color = state.to_move in
        (match capture, Board.get board destination with
         | true, (Some Piece.{ color = piece_color; _ }) when not (Color.equal piece_color color) -> ()
         | true, _ -> failwith "capture expected"
         | false, None -> ()
         | false, (Some Piece.{ color = piece_color; _ }) when Color.equal piece_color color -> failwith "destination occupied by own piece"
         | false, Some _ -> failwith "unexpected capture");
        let sources = Engine.find_piece_sources board color kind destination dis_file dis_rank in
        let src =
          match sources with
          | [ square ] -> square
          | [] -> failwith "no source square found"
          | _ -> failwith "ambiguous SAN (multiple sources)"
        in
        Engine.update_castling_on_rook_move state color src;
        (match kind with Piece_kind.King -> Engine.update_castling_on_king_move state color | _ -> ());
        let captured = Board.move board ~src ~dst:destination in
        (match captured with
         | Some Piece.{ color = piece_color; kind = piece_kind }
           when Piece_kind.equal piece_kind Piece_kind.Rook && not (Color.equal piece_color color) ->
             Engine.remove_castling_rights_on_capture state destination
         | _ -> ());
        state.en_passant <- None;
        state.halfmove_clock <- (match captured with Some _ -> 0 | None -> state.halfmove_clock + 1);
        Engine.advance_turn state)

let apply_pawn_move state ~from_file ~capture ~destination ~promotion =
  Or_error.try_with (fun () ->
      let color = state.State.to_move in
      let board = state.board in
      let sources = find_pawn_sources state color ~capture ~from_file destination in
      let src =
        match sources with
        | [ square ] -> square
        | [] -> failwith "no pawn source found"
        | _ -> failwith "ambiguous pawn move"
      in
      let dest_piece = Board.get board destination in
      let dir = Engine.direction color in
      let en_passant_capture =
        capture
        && Option.is_none dest_piece
        && Option.exists state.en_passant ~f:(fun sq -> Poly.equal sq destination)
      in
      if capture && not en_passant_capture then
        match dest_piece with
        | Some Piece.{ color = piece_color; _ } when Color.equal piece_color color -> failwith "capture hitting own piece"
        | Some _ -> ()
        | None -> ()
      else if not capture && Option.is_some dest_piece then
        failwith "pawn move destination occupied";
      (* Handle en passant capture before move *)
      if en_passant_capture then begin
        let captured_square = (fst destination, snd destination - dir) in
        Board.set board captured_square None
      end;
      ignore (Board.move board ~src ~dst:destination);
      (match promotion with
       | Some kind -> Board.set board destination (Some Piece.{ color; kind })
       | None -> ());
      (match dest_piece with
       | Some Piece.{ color = piece_color; kind = piece_kind }
         when Piece_kind.equal piece_kind Piece_kind.Rook && not (Color.equal piece_color color) ->
         Engine.remove_castling_rights_on_capture state destination
       | _ -> ());
      state.en_passant <-
        (let src_rank = snd src in
         if not capture && Int.abs (snd destination - src_rank) = 2 then
           Some (fst destination, src_rank + dir)
         else None);
      state.halfmove_clock <- 0;
      Engine.advance_turn state)

let apply_san state san =
  match san with
  | San.Castle_kingside -> apply_castle state `Kingside
  | San.Castle_queenside -> apply_castle state `Queenside
  | San.Piece move ->
      apply_piece_move state ~kind:move.kind ~dis_file:move.disambig_file ~dis_rank:move.disambig_rank
        ~capture:move.capture ~destination:move.destination ~promotion:move.promotion
  | San.Pawn move ->
      apply_pawn_move state ~from_file:move.from_file ~capture:move.capture ~destination:move.destination ~promotion:move.promotion

let parse_san token = Or_error.try_with (fun () -> San.parse token)

let fens_of_moves san_list =
  let state = State.initial () in
  List.fold san_list ~init:(Or_error.return []) ~f:(fun acc san_str ->
      Or_error.bind acc ~f:(fun acc ->
          Or_error.bind (parse_san san_str) ~f:(fun san ->
              Or_error.bind (apply_san state san) ~f:(fun () ->
                  Or_error.return (Fen.to_string state :: acc)))))
  |> Or_error.map ~f:List.rev

let fens_of_string contents =
  Or_error.bind (Pgn_parser.parse contents) ~f:(fun parsed ->
      let sans = List.map parsed.moves ~f:(fun move -> move.san) in
      fens_of_moves sans)

let fens_of_file path =
  Or_error.bind (Or_error.try_with (fun () -> Stdio.In_channel.read_all path)) ~f:fens_of_string

let fen_after_move pgn ~color ~move_number =
  if move_number <= 0 then Or_error.error_string "move_number must be positive"
  else
    Or_error.bind (Pgn_parser.parse pgn) ~f:(fun parsed ->
        let sans = List.map parsed.moves ~f:(fun move -> move.san) in
        Or_error.bind (fens_of_moves sans) ~f:(fun fens ->
            let base = (move_number - 1) * 2 in
            let idx =
              match color with
              | `White -> base
              | `Black -> base + 1
            in
            match List.nth fens idx with
            | Some fen -> Or_error.return fen
            | None ->
                let player = match color with `White -> "White" | `Black -> "Black" in
                Or_error.errorf "PGN does not contain move %d for %s" move_number player))
