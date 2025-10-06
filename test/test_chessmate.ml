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
open Stdio
open Alcotest
open Chessmate

let load_fixture name =
  let source_root = Stdlib.Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"." in
  let path = Stdlib.Filename.concat source_root (Stdlib.Filename.concat "test/fixtures" name) in
  In_channel.read_all path

let test_parse_sample_game () =
  let sample_pgn = load_fixture "sample_game.pgn" in
  match Pgn_parser.parse sample_pgn with
  | Error err -> failf "unexpected parse failure: %s" (Error.to_string_hum err)
  | Ok parsed ->
      let headers = parsed.headers in
      let moves = parsed.moves in
      check int "header count" 6 (List.length headers);
      check int "ply count" 6 (Pgn_parser.ply_count parsed);
      check (option string) "white header" (Some "Sample White") (Pgn_parser.white_name parsed);
      check (option string) "black header" (Some "Sample Black") (Pgn_parser.black_name parsed);
      check (option string) "result header" (Some "1-0") (Pgn_parser.result parsed);
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
      (match Pgn_parser.black_move parsed 3 with
      | Some move -> check string "black move 3" "a6" move.san
      | None -> fail "missing black move 3")

let test_parse_invalid () =
  let invalid = "[Event \"Test\"]\n\n*" in
  match Pgn_parser.parse invalid with
  | Ok _ -> fail "expected parse failure"
  | Error _ -> ()

let test_parse_extended_sample_game () =
  let source_root = Stdlib.Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"." in
  let filename = Stdlib.Filename.concat source_root "test/fixtures/extended_sample_game.pgn" in
  match In_channel.read_all filename |> Pgn_parser.parse with
  | Error err -> failf "failed to parse sample PGN: %s" (Error.to_string_hum err)
  | Ok parsed ->
      printf "Parsed headers:\n";
      List.iter parsed.headers ~f:(fun (key, value) -> printf "  %s: %s\n" key value);
      printf "Parsed moves:\n";
      List.iter parsed.moves ~f:(fun move ->
          printf "  ply=%d turn=%d san=%s\n" move.ply move.turn move.san);
      check (option string) "event" (Some "Interpolis International Tournament") (Pgn_parser.event parsed);
      check (option string) "site" (Some "Tilburg NED") (Pgn_parser.site parsed);
      check (option string) "round" (Some "1.1") (Pgn_parser.round parsed);
      check (option string) "white name" (Some "Seirawan, Y") (Pgn_parser.white_name parsed);
      check (option string) "black name" (Some "Smyslov, V") (Pgn_parser.black_name parsed);
      check (option int) "white elo" (Some 2568) (Pgn_parser.white_rating parsed);
      check (option int) "black elo" (Some 2690) (Pgn_parser.black_rating parsed);
      check (option string) "result" (Some "0-1") (Pgn_parser.result parsed);
      check (option string) "event date" (Some "1994.09.10") (Pgn_parser.event_date parsed);
      check int "move count" 77 (List.length parsed.moves);
      let last = List.last_exn parsed.moves in
      check string "last move" "Ke2" last.san;
      check int "last ply" 77 last.ply;
      check int "ply count" 77 (Pgn_parser.ply_count parsed);
      check bool "analysis move filtered" true
        (not (List.exists parsed.moves ~f:(fun move -> String.equal move.san "Kd6")));
      check (option string) "tag test1" (Some "VALUE_TEST_TAG_1") (Pgn_parser.tag_value parsed "TEST_TAG_1");
      check (option string) "white player" (Some "Seirawan, Y") (Pgn_parser.white_name parsed);
      check (option string) "black player" (Some "Smyslov, V") (Pgn_parser.black_name parsed);
      (match Pgn_parser.white_move parsed 17 with
      | Some move -> check string "white move 17" "Qh7" move.san
      | None -> fail "missing white move 17");
      (match Pgn_parser.black_move parsed 17 with
      | Some move -> check string "black move 17" "f6" move.san
      | None -> fail "missing black move 17")

let test_metadata_from_headers () =
  let headers =
    [ "Event", "Championship";
      "Site", "Paris";
      "Date", "2024.??.12";
      "Round", "3";
      "White", "Carlsen";
      "Black", "Nepomniachtchi";
      "WhiteElo", "2855";
      "Result", "1-0";
      "ECO", "B33" ]
  in
  let meta = Game_metadata.of_headers headers in
  check (option string) "event" (Some "Championship") meta.event;
  check (option string) "site" (Some "Paris") meta.site;
  check (option string) "date" (Some "2024-01-12") meta.date;
  check (option string) "eco" (Some "B33") meta.eco_code;
  check (option string) "opening name" (Some "Sicilian Defense") meta.opening_name;
  check (option string) "opening slug" (Some "sicilian_defense") meta.opening_slug;
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
        [ "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1"
        ; "rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 1 2"
        ; "rnbqkb1r/pppppppp/5n2/8/2PP4/8/PP2PPPP/RNBQKBNR b KQkq c3 0 2"
        ; "rnbqkb1r/pppp1ppp/4pn2/8/2PP4/8/PP2PPPP/RNBQKBNR w KQkq - 0 3"
        ; "rnbqkb1r/pppp1ppp/4pn2/8/2PP4/5N2/PP2PPPP/RNBQKB1R b KQkq - 1 3"
        ; "rnbqk2r/pppp1ppp/4pn2/8/1bPP4/5N2/PP2PPPP/RNBQKB1R w KQkq - 2 4"
        ; "rnbqk2r/pppp1ppp/4pn2/8/1bPP4/5N2/PP1NPPPP/R1BQKB1R b KQkq - 3 4"
        ; "rnbqk2r/pp1p1ppp/4pn2/2p5/1bPP4/5N2/PP1NPPPP/R1BQKB1R w KQkq c6 0 5"
        ; "rnbqk2r/pp1p1ppp/4pn2/2p5/1bPP4/P4N2/1P1NPPPP/R1BQKB1R b KQkq - 0 5"
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

let to_filter_pairs filters =
  List.map filters ~f:(fun f -> f.Query_intent.field, f.Query_intent.value)

let test_query_intent_opening () =
  let request =
    { Query_intent.text =
        "Find top 3 King's Indian games where white is rated at least 2500 and black is 100 points lower"
    }
  in
  let plan = Query_intent.analyse request in
  check int "limit" 3 plan.Query_intent.limit;
  check (option int) "white min" (Some 2500) plan.Query_intent.rating.white_min;
  check (option int) "black min" None plan.Query_intent.rating.black_min;
  check (option int) "rating delta" (Some 100) plan.Query_intent.rating.max_rating_delta;
  let filters = to_filter_pairs plan.Query_intent.filters in
  let has_opening_filter =
    List.exists filters ~f:(fun (field, value) ->
        String.equal field "opening" && String.equal value "kings_indian_defense")
  in
  check bool "opening filter" true has_opening_filter;
  check bool "keyword includes indian" true (List.mem plan.Query_intent.keywords "indian" ~equal:String.equal)

let test_query_intent_draw () =
  let request =
    { Query_intent.text = "Show me five games that end in a draw in the French Defense endgame" }
  in
  let plan = Query_intent.analyse request in
  check int "limit fallback" 5 plan.Query_intent.limit;
  let filters = to_filter_pairs plan.Query_intent.filters in
  let expect_pairs =
    [ "opening", "french_defense";
      "phase", "endgame";
      "result", "1/2-1/2" ]
  in
  List.iter expect_pairs ~f:(fun expected ->
      let has_filter =
        List.mem filters expected ~equal:(fun (a1, b1) (a2, b2) -> String.equal a1 a2 && String.equal b1 b2)
      in
      check bool "expected filter present" true has_filter)

let suite =
  [ "parse sample game", `Quick, test_parse_sample_game;
    "parse invalid", `Quick, test_parse_invalid;
    "parse extended sample game", `Quick, test_parse_extended_sample_game;
    "metadata extraction", `Quick, test_metadata_from_headers;
    "sample FEN sequence", `Quick, test_fen_sequence_sample;
    "fen after move", `Quick, test_fen_after_move;
    "query intent opening", `Quick, test_query_intent_opening;
    "query intent draw", `Quick, test_query_intent_draw
  ]

let () =
  run "chessmate" [ "core", suite ]
