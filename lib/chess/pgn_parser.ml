(** Stream PGN files into structured games with headers and SAN move lists,
    emitting incremental results suitable for concurrent ingestion. *)

open! Base
open! Lwt.Infix

type move = { san : string; turn : int; ply : int }
type t = { headers : (string * string) list; moves : move list }
type partial_game = { lines : string list; have_moves : bool }

let default_valid_results = [ "1-0"; "0-1"; "1/2-1/2"; "*" ]
let find_header headers key = List.Assoc.find headers ~equal:String.equal key
let tag_value t key = find_header t.headers key
let ply_count t = List.length t.moves
let parse_int_opt value = Option.bind value ~f:Int.of_string_opt
let white_name t = tag_value t "White"
let black_name t = tag_value t "Black"
let white_rating t = tag_value t "WhiteElo" |> parse_int_opt
let black_rating t = tag_value t "BlackElo" |> parse_int_opt
let event t = tag_value t "Event"
let site t = tag_value t "Site"
let round t = tag_value t "Round"
let result t = tag_value t "Result"
let event_date t = tag_value t "EventDate"

let white_move t move_number =
  List.find t.moves ~f:(fun move ->
      Int.(move.turn = move_number) && Int.(move.ply % 2 = 1))

let black_move t move_number =
  List.find t.moves ~f:(fun move ->
      Int.(move.turn = move_number) && Int.(move.ply % 2 = 0))

let drop_while s ~f =
  let len = String.length s in
  let rec find i =
    if i >= len then len else if f s.[i] then find (i + 1) else i
  in
  let idx = find 0 in
  String.sub s ~pos:idx ~len:(len - idx)

let strip_comments text =
  let len = String.length text in
  let buffer = Stdlib.Buffer.create len in
  let is_line_start idx = Int.equal idx 0 || Char.equal text.[idx - 1] '\n' in
  let rec loop i state =
    if i >= len then ()
    else
      let char = text.[i] in
      match state with
      | `Normal -> (
          match char with
          | '{' -> loop (i + 1) `Brace
          | '(' -> loop (i + 1) `Paren
          | ';' -> loop (i + 1) `Line_comment
          | '%' when is_line_start i -> loop (i + 1) `Percent_comment
          | _ ->
              Stdlib.Buffer.add_char buffer char;
              loop (i + 1) `Normal)
      | `Brace ->
          if Char.(char = '}') then loop (i + 1) `Normal
          else loop (i + 1) `Brace
      | `Paren ->
          if Char.(char = ')') then loop (i + 1) `Normal
          else loop (i + 1) `Paren
      | `Line_comment ->
          if Char.(char = '\n') then (
            Stdlib.Buffer.add_char buffer char;
            loop (i + 1) `Normal)
          else loop (i + 1) `Line_comment
      | `Percent_comment ->
          if Char.(char = '\n') then (
            Stdlib.Buffer.add_char buffer char;
            loop (i + 1) `Normal)
          else loop (i + 1) `Percent_comment
  in
  loop 0 `Normal;
  Stdlib.Buffer.contents buffer

let parse_header_line line =
  match String.chop_prefix line ~prefix:"[" with
  | None -> Or_error.errorf "Invalid PGN header line: %s" line
  | Some rest -> (
      match String.chop_suffix rest ~suffix:"]" with
      | None -> Or_error.errorf "Invalid PGN header line: %s" line
      | Some inner -> (
          let trimmed = String.strip inner in
          let parts = String.split ~on:' ' trimmed in
          match parts with
          | [] -> Or_error.errorf "Invalid PGN header line: %s" line
          | key :: value_parts ->
              let value_raw =
                String.concat ~sep:" " value_parts |> String.strip
              in
              let len = String.length value_raw in
              let value =
                if
                  len >= 2
                  && Char.(value_raw.[0] = '"')
                  && Char.(value_raw.[len - 1] = '"')
                then String.sub value_raw ~pos:1 ~len:(len - 2)
                else value_raw
              in
              Ok (key, value)))

let rec collect_headers_and_moves lines headers =
  match lines with
  | [] -> Or_error.return (List.rev headers, [])
  | line :: rest ->
      let trimmed = String.strip line in
      if String.is_empty trimmed then collect_headers_and_moves rest headers
      else if String.is_prefix trimmed ~prefix:"[" then
        Or_error.bind (parse_header_line trimmed) ~f:(fun header ->
            collect_headers_and_moves rest (header :: headers))
      else
        let remaining = trimmed :: rest in
        Or_error.return (List.rev headers, remaining)

let is_result_token token =
  match token with "1-0" | "0-1" | "1/2-1/2" | "*" -> true | _ -> false

let parse_moves move_lines =
  let raw_text =
    move_lines |> List.map ~f:String.strip
    |> List.filter ~f:(fun s -> not (String.is_empty s))
    |> String.concat ~sep:" "
  in
  if String.is_empty raw_text then
    Or_error.error_string "No moves found in PGN body"
  else
    let tokens =
      raw_text
      |> String.split_on_chars ~on:[ ' '; '\t'; '\r'; '\n' ]
      |> List.filter ~f:(fun tok -> not (String.is_empty (String.strip tok)))
    in
    let rec loop tokens acc current_turn ply =
      match tokens with
      | [] -> Or_error.return acc
      | token :: rest ->
          let token = String.strip token in
          if String.is_empty token then loop rest acc current_turn ply
          else if is_result_token token then Or_error.return acc
          else if Char.(token.[0] = '$') then loop rest acc current_turn ply
          else
            let len = String.length token in
            let rec count_digits idx =
              if idx < len && Char.is_digit token.[idx] then
                count_digits (idx + 1)
              else idx
            in
            let digit_count = count_digits 0 in
            let new_turn, body =
              if digit_count > 0 then
                let digits = String.sub token ~pos:0 ~len:digit_count in
                match Int.of_string_opt digits with
                | None -> (current_turn, token)
                | Some turn_num ->
                    let remainder =
                      String.sub token ~pos:digit_count ~len:(len - digit_count)
                    in
                    let remainder =
                      drop_while remainder ~f:(Char.equal '.') |> String.strip
                    in
                    (turn_num, remainder)
              else (current_turn, token)
            in
            let body = drop_while body ~f:(Char.equal '.') |> String.strip in
            if String.is_empty body then
              let updated_turn =
                if Int.(new_turn > 0) then new_turn else current_turn
              in
              loop rest acc updated_turn ply
            else
              let next_ply = ply + 1 in
              let effective_turn =
                if Int.(new_turn > 0) then new_turn else (next_ply + 1) / 2
              in
              let move =
                { san = body; turn = effective_turn; ply = next_ply }
              in
              let next_turn =
                if Int.(next_ply % 2 = 0) then effective_turn + 1
                else effective_turn
              in
              loop rest (move :: acc) next_turn next_ply
    in
    loop tokens [] 0 0 |> Or_error.map ~f:List.rev

let parse raw_pgn =
  let sanitized = strip_comments raw_pgn in
  let lines = String.split_lines sanitized in
  Or_error.bind (collect_headers_and_moves lines [])
    ~f:(fun (headers, move_lines) ->
      Or_error.bind (parse_moves move_lines) ~f:(fun moves ->
          if List.is_empty moves then
            Or_error.error_string "PGN contained no moves"
          else Or_error.return { headers; moves }))

let parse_file path =
  Or_error.bind
    (Or_error.try_with (fun () -> Stdio.In_channel.read_all path))
    ~f:parse

let fold_games ?on_error raw ~init ~f =
  let handle_error =
    match on_error with
    | None ->
        fun _state ~index ~raw:_ err ->
          Or_error.tag (Error err) ~tag:(Printf.sprintf "PGN game #%d" index)
    | Some handler -> handler
  in
  let lines = String.split_lines raw in
  let empty : partial_game = { lines = []; have_moves = false } in
  let finalise collector state count =
    match collector.lines with
    | [] -> Or_error.return (state, count)
    | lines -> (
        let raw_game =
          lines |> List.rev |> String.concat ~sep:"\n" |> String.strip
        in
        if String.is_empty raw_game then Or_error.return (state, count)
        else
          let next_index = count + 1 in
          match parse raw_game with
          | Ok parsed ->
              f state ~index:next_index ~raw:raw_game parsed
              |> Or_error.map ~f:(fun state' -> (state', next_index))
          | Error err ->
              handle_error state ~index:next_index ~raw:raw_game err
              |> Or_error.map ~f:(fun state' -> (state', next_index)))
  in
  let rec step remaining collector state count =
    match remaining with
    | [] -> finalise collector state count |> Or_error.map ~f:fst
    | line :: rest ->
        let trimmed = String.strip line in
        let is_header = String.is_prefix trimmed ~prefix:"[" in
        let is_event = String.is_prefix trimmed ~prefix:"[Event" in
        let has_move_token = (not is_header) && not (String.is_empty trimmed) in
        let should_start_new_game =
          is_event && collector.have_moves
          && not (List.is_empty collector.lines)
        in
        if should_start_new_game then
          finalise collector state count
          |> Or_error.bind ~f:(fun (state', next_index) ->
                 let next_collector : partial_game =
                   { lines = [ line ]; have_moves = false }
                 in
                 step rest next_collector state' next_index)
        else
          let next_collector : partial_game =
            {
              lines = line :: collector.lines;
              have_moves = collector.have_moves || has_move_token;
            }
          in
          step rest next_collector state count
  in
  step lines empty init 0

let parse_games raw =
  fold_games raw ~init:[] ~f:(fun acc ~index:_ ~raw:_ game ->
      Or_error.return (game :: acc))
  |> Or_error.map ~f:List.rev

let parse_file_games path =
  Or_error.bind
    (Or_error.try_with (fun () -> Stdio.In_channel.read_all path))
    ~f:parse_games

let stream_games ?on_error raw ~f =
  let handler =
    match on_error with
    | Some on_error -> on_error
    | None ->
        fun ~index ~raw:_ err ->
          Lwt.fail
            (Failure
               (Printf.sprintf "PGN game #%d: %s" index
                  (Error.to_string_hum err)))
  in
  let lines = String.split_lines raw in
  let empty : partial_game = { lines = []; have_moves = false } in
  let finalise collector index =
    match collector.lines with
    | [] -> Lwt.return index
    | lines -> (
        let raw_game =
          lines |> List.rev |> String.concat ~sep:"\n" |> String.strip
        in
        if String.is_empty raw_game then Lwt.return index
        else
          let next_index = index + 1 in
          match parse raw_game with
          | Ok parsed ->
              f ~index:next_index ~raw:raw_game parsed >|= fun () -> next_index
          | Error err ->
              handler ~index:next_index ~raw:raw_game err >|= fun () ->
              next_index)
  in
  let rec step remaining collector index =
    match remaining with
    | [] -> finalise collector index >|= fun _ -> ()
    | line :: rest ->
        let trimmed = String.strip line in
        let is_header = String.is_prefix trimmed ~prefix:"[" in
        let is_event = String.is_prefix trimmed ~prefix:"[Event" in
        let has_move_token = (not is_header) && not (String.is_empty trimmed) in
        let should_start_new_game =
          is_event && collector.have_moves
          && not (List.is_empty collector.lines)
        in
        if should_start_new_game then
          finalise collector index >>= fun next_index ->
          let next_collector : partial_game =
            { lines = [ line ]; have_moves = false }
          in
          step rest next_collector next_index
        else
          let next_collector : partial_game =
            {
              lines = line :: collector.lines;
              have_moves = collector.have_moves || has_move_token;
            }
          in
          step rest next_collector index
  in
  step lines empty 0
