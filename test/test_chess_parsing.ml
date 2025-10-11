open! Base
open Alcotest
open Chessmate

let load_fixture = Test_support.load_fixture

let test_parse_sample_game () =
  let sample_pgn = load_fixture "sample_game.pgn" in
  match Pgn_parser.parse sample_pgn with
  | Error err -> failf "unexpected parse failure: %s" (Error.to_string_hum err)
  | Ok parsed -> (
      let headers = parsed.headers in
      let moves = parsed.moves in
      check int "header count" 6 (List.length headers);
      check int "ply count" 6 (Pgn_parser.ply_count parsed);
      check (option string) "white header" (Some "Sample White")
        (Pgn_parser.white_name parsed);
      check (option string) "black header" (Some "Sample Black")
        (Pgn_parser.black_name parsed);
      check (option string) "result header" (Some "1-0")
        (Pgn_parser.result parsed);
      check (option int) "white elo" None (Pgn_parser.white_rating parsed);
      check (option int) "black elo" None (Pgn_parser.black_rating parsed);
      check int "move count" 6 (List.length moves);
      let first_move = List.hd_exn moves in
      check string "first move" "e4" first_move.san;
      check int "first turn" 1 first_move.turn;
      let last_move = List.last_exn moves in
      check string "last move" "a6" last_move.san;
      check int "last ply" 6 last_move.ply;
      (match Pgn_parser.white_move parsed 3 with
      | Some move -> check string "white move 3" "Bb5" move.san
      | None -> fail "missing white move 3");
      match Pgn_parser.black_move parsed 3 with
      | Some move -> check string "black move 3" "a6" move.san
      | None -> fail "missing black move 3")

let test_parse_invalid () =
  let invalid = "[Event \"Test\"]\n\n*" in
  match Pgn_parser.parse invalid with
  | Ok _ -> fail "expected parse failure"
  | Error _ -> ()

let test_castle_requires_clear_path () =
  let pgn =
    {|
[Event "Illegal castle"]
[Site "Testville"]
[Date "2024.01.01"]
[Round "1"]
[White "Alpha"]
[Black "Beta"]
[Result "*"]

1. O-O *
|}
  in
  match Pgn_to_fen.fens_of_string pgn with
  | Ok _ -> fail "expected castling validation failure"
  | Error err ->
      let message = Error.to_string_hum err in
      check bool "mentions castling" true
        (String.is_substring message ~substring:"cannot castle")

let test_capture_requires_target () =
  let pgn =
    {|
[Event "Illegal capture"]
[Site "Testville"]
[Date "2024.01.01"]
[Round "1"]
[White "Alpha"]
[Black "Beta"]
[Result "*"]

1. exd5 *
|}
  in
  match Pgn_to_fen.fens_of_string pgn with
  | Ok _ -> fail "expected capture validation failure"
  | Error err ->
      let message = Error.to_string_hum err in
      check bool "mentions expected capture" true
        (String.is_substring message ~substring:"expected capture on d5")

let test_parse_extended_sample_game () =
  let filename = "extended_sample_game.pgn" in
  match load_fixture filename |> Pgn_parser.parse with
  | Error err ->
      failf "failed to parse sample PGN: %s" (Error.to_string_hum err)
  | Ok parsed ->
      let moves = parsed.moves in
      check (option string) "event" (Some "Interpolis International Tournament")
        (Pgn_parser.event parsed);
      check (option string) "site" (Some "Tilburg NED") (Pgn_parser.site parsed);
      check (option string) "round" (Some "1.1") (Pgn_parser.round parsed);
      check (option string) "white name" (Some "Seirawan, Y")
        (Pgn_parser.white_name parsed);
      check (option string) "black name" (Some "Smyslov, V")
        (Pgn_parser.black_name parsed);
      check (option int) "white elo" (Some 2568)
        (Pgn_parser.white_rating parsed);
      check (option int) "black elo" (Some 2690)
        (Pgn_parser.black_rating parsed);
      check (option string) "result" (Some "0-1") (Pgn_parser.result parsed);
      check (option string) "event date" (Some "1994.09.10")
        (Pgn_parser.event_date parsed);
      check int "move count" 77 (List.length moves);
      let last = List.last_exn moves in
      check string "last move" "Ke2" last.san;
      check int "last ply" 77 last.ply;
      check int "ply count" 77 (Pgn_parser.ply_count parsed);
      check bool "analysis move filtered" true
        (not (List.exists moves ~f:(fun move -> String.equal move.san "Kd6")));
      check (option string) "tag test1" (Some "VALUE_TEST_TAG_1")
        (Pgn_parser.tag_value parsed "TEST_TAG_1")

let test_metadata_from_headers () =
  let headers =
    [
      ("Event", "Championship");
      ("Site", "Paris");
      ("Date", "2024.??.12");
      ("Round", "3");
      ("White", "Carlsen");
      ("Black", "Nepomniachtchi");
      ("WhiteElo", "2855");
      ("Result", "1-0");
      ("ECO", "B33");
    ]
  in
  let meta = Game_metadata.of_headers headers in
  check (option string) "event" (Some "Championship") meta.event;
  check (option string) "site" (Some "Paris") meta.site;
  check (option string) "date" (Some "2024-01-12") meta.date;
  check (option string) "eco" (Some "B33") meta.eco_code;
  check (option string) "opening name" (Some "Sicilian Defense")
    meta.opening_name;
  check (option string) "opening slug" (Some "sicilian_defense")
    meta.opening_slug;
  check string "white name" "Carlsen" meta.white.name;
  check (option int) "white rating" (Some 2855) meta.white.rating;
  check string "black name" "Nepomniachtchi" meta.black.name

let test_fen_sequence_sample () =
  let sample_pgn = load_fixture "extended_sample_game.pgn" in
  match Pgn_to_fen.fens_of_string sample_pgn with
  | Error err -> failf "FEN generation failed: %s" (Error.to_string_hum err)
  | Ok fens ->
      check int "total plies" 77 (List.length fens);
      let expected_prefix =
        [
          "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1";
          "rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2";
          "rnbqkb1r/pppppppp/5n2/8/2PP4/8/PP2PPPP/RNBQKBNR b KQkq c3 0 2";
        ]
      in
      let actual_prefix = List.take fens (List.length expected_prefix) in
      check (list string) "FEN prefix" expected_prefix actual_prefix

let test_fen_after_move () =
  let pgn = load_fixture "extended_sample_game.pgn" in
  match Pgn_to_fen.fen_after_move pgn ~color:`White ~move_number:39 with
  | Error err -> failf "fen_after_move failure: %s" (Error.to_string_hum err)
  | Ok fen ->
      check string "FEN after white 39"
        "8/p1kb1R2/1p3p2/2p5/2P1P1p1/PP2Pr2/4K3/8 b - - 2 39" fen

let multi_game_pgn =
  {|
[Event "Game One"]
[Site "Testville"]
[Date "2024.01.01"]
[Round "1"]
[White "Alpha"]
[Black "Beta"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 1-0

[Event "Game Two"]
[Site "Testville"]
[Date "2024.01.02"]
[Round "2"]
[White "Gamma"]
[Black "Delta"]
[Result "0-1"]

1. d4 d5 2. c4 e6 3. Nc3 Nf6 4. Bg5 Be7 0-1
|}

let test_parse_multiple_games () =
  match Pgn_parser.parse_games multi_game_pgn with
  | Error err -> failf "multi-game parse failed: %s" (Error.to_string_hum err)
  | Ok games ->
      check int "game count" 2 (List.length games);
      let first = List.hd_exn games in
      let second = List.nth_exn games 1 in
      check (option string) "first result" (Some "1-0")
        (Pgn_parser.result first);
      check (option string) "second result" (Some "0-1")
        (Pgn_parser.result second)

let test_fold_games_preserves_raw () =
  match
    Pgn_parser.fold_games multi_game_pgn ~init:[]
      ~f:(fun acc ~index ~raw game ->
        ignore game;
        Or_error.return ((index, raw) :: acc))
  with
  | Error err -> failf "fold_games failed: %s" (Error.to_string_hum err)
  | Ok games -> (
      let ordered = List.rev games in
      match ordered with
      | [ (first_index, first_raw); (second_index, second_raw) ] ->
          check int "first index" 1 first_index;
          check int "second index" 2 second_index;
          check bool "first raw retains header" true
            (String.is_substring first_raw ~substring:"[Event \"Game One\"]");
          check bool "second raw retains header" true
            (String.is_substring second_raw ~substring:"[Event \"Game Two\"]")
      | _ -> fail "unexpected number of games from fold")

let malformed_twic_excerpt =
  {|
[Event "Valid"]
[Site "Testville"]
[Date "2024.01.03"]
[Round "3"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 1-0

[Event "Broken
This is editorial commentary without proper PGN formatting.
|}

let test_fold_games_reports_parse_errors () =
  let handler acc ~index ~raw err =
    Or_error.return ((index, Error.to_string_hum err, raw) :: acc)
  in
  match
    Pgn_parser.fold_games ~on_error:handler malformed_twic_excerpt ~init:[]
      ~f:(fun acc ~index:_ ~raw:_ _ -> Or_error.return acc)
  with
  | Error err ->
      failf "fold_games unexpectedly aborted: %s" (Error.to_string_hum err)
  | Ok issues -> (
      match issues with
      | [ (index, message, raw) ] ->
          check int "parse error index" 2 index;
          check bool "non-empty error message"
            (not (String.is_empty message))
            true;
          check bool "preview includes commentary" true
            (String.is_substring raw ~substring:"editorial commentary")
      | _ -> fail "expected exactly one parse error")

let suite =
  [
    ("parse sample game", `Quick, test_parse_sample_game);
    ("parse invalid", `Quick, test_parse_invalid);
    ("illegal castle rejected", `Quick, test_castle_requires_clear_path);
    ("invalid capture rejected", `Quick, test_capture_requires_target);
    ("parse extended sample game", `Quick, test_parse_extended_sample_game);
    ("metadata extraction", `Quick, test_metadata_from_headers);
    ("sample FEN sequence", `Quick, test_fen_sequence_sample);
    ("fen after move", `Quick, test_fen_after_move);
    ("parse multiple games", `Quick, test_parse_multiple_games);
    ("fold games preserves raw", `Quick, test_fold_games_preserves_raw);
    ( "fold games reports parse errors",
      `Quick,
      test_fold_games_reports_parse_errors );
  ]
