open! Base
open Stdio
open Alcotest

let sample_pgn = {|
[Event "Test Event"]
[Site "Somewhere"]
[Date "2024.01.01"]
[White "Sample White"]
[Black "Sample Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0
|}

let test_parse_success () =
  match Chessmate.Pgn_parser.parse sample_pgn with
  | Error err -> failf "unexpected parse failure: %s" (Error.to_string_hum err)
  | Ok parsed ->
      let headers = parsed.headers in
      let moves = parsed.moves in
      let find_header key = List.Assoc.find headers ~equal:String.equal key in
      check (option string) "white header" (Some "Sample White") (find_header "White");
      check (option string) "result header" (Some "1-0") (find_header "Result");
      check int "move count" 6 (List.length moves);
      let first_move = List.hd_exn moves in
      check string "first move" "e4" first_move.san;
      check int "first turn" 1 first_move.turn;
      check int "first ply" 1 first_move.ply;
      let last_move = List.last_exn moves in
      check string "last move" "a6" last_move.san;
      check int "last ply" 6 last_move.ply

let test_parse_invalid () =
  let invalid = "[Event \"Test\"]\n\n*" in
  match Chessmate.Pgn_parser.parse invalid with
  | Ok _ -> fail "expected parse failure"
  | Error _ -> ()

let test_parse_sample_file () =
  let source_root = Stdlib.Sys.getenv_opt "DUNE_SOURCEROOT" |> Option.value ~default:"." in
  let filename = Stdlib.Filename.concat source_root "data/games/sample_game.pgn" in
  match In_channel.read_all filename |> Chessmate.Pgn_parser.parse with
  | Error err -> failf "failed to parse sample PGN: %s" (Error.to_string_hum err)
  | Ok parsed ->
      printf "Parsed headers:\n";
      List.iter parsed.headers ~f:(fun (key, value) -> printf "  %s: %s\n" key value);
      printf "Parsed moves:\n";
      List.iter parsed.moves ~f:(fun move ->
          printf "  ply=%d turn=%d san=%s\n" move.ply move.turn move.san);
      check int "header count" 8 (List.length parsed.headers);
      check int "move count" 45 (List.length parsed.moves);
      let last = List.last_exn parsed.moves in
      check string "last move" "Qxg7#" last.san;
      check int "last ply" 45 last.ply;
      let white = List.Assoc.find parsed.headers ~equal:String.equal "White" in
      check (option string) "white player" (Some "Alpha") white

let suite =
  [ "parse success", `Quick, test_parse_success;
    "parse invalid", `Quick, test_parse_invalid;
    "parse sample file", `Quick, test_parse_sample_file
  ]

let () =
  run "chessmate" [ "core", suite ]
