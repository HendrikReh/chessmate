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
  check string "white name" "Carlsen" meta.white.name;
  check (option int) "white rating" (Some 2855) meta.white.rating;
  check string "black name" "Nepomniachtchi" meta.black.name

let suite =
  [ "parse sample game", `Quick, test_parse_sample_game;
    "parse invalid", `Quick, test_parse_invalid;
    "parse extended sample game", `Quick, test_parse_extended_sample_game;
    "metadata extraction", `Quick, test_metadata_from_headers
  ]

let () =
  run "chessmate" [ "core", suite ]
