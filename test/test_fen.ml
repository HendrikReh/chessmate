open! Base
open Alcotest
open Chessmate

let expect_ok ?(msg = "FEN should normalize") fen expected =
  match Fen.normalize fen with
  | Ok normalized -> check string msg expected normalized
  | Error err -> failf "%s: %s" msg (Error.to_string_hum err)

let expect_error ?(msg = "expected normalization failure") fen =
  match Fen.normalize fen with
  | Ok normalized -> failf "%s but got %s" msg normalized
  | Error _ -> ()

let test_valid_initial_position () =
  expect_ok ~msg:"initial position"
    "  rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR   w  KQkq  -   0  1 "
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

let test_valid_en_passant () =
  expect_ok ~msg:"en passant square"
    "rnbqkbnr/pppp1ppp/8/4p3/2P5/8/PP1PPPPP/RNBQKBNR w KQkq e6 0 3"
    "rnbqkbnr/pppp1ppp/8/4p3/2P5/8/PP1PPPPP/RNBQKBNR w KQkq e6 0 3"

let test_invalid_field_count () =
  expect_error ~msg:"missing fields should fail"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0"

let test_invalid_rank_square_count () =
  expect_error ~msg:"rank with too many squares should fail"
    "8/8/8/8/8/8/8/9 w - - 0 1"

let test_missing_king () =
  expect_error ~msg:"position without both kings must fail"
    "rnbq1bnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQ - 0 1"

let test_pawn_on_back_rank () =
  expect_error ~msg:"pawns on first rank are illegal"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/PNRQKBNR w KQkq - 0 1"

let test_invalid_en_passant_rank () =
  expect_error ~msg:"en passant rank must match side to move"
    "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq c3 0 2"

let test_duplicate_castling_rights () =
  expect_error ~msg:"duplicate castling symbols should fail"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KKq - 0 1"

let test_fixture_fens_normalize () =
  let sample = Test_support.load_fixture "extended_sample_game.pgn" in
  match Pgn_to_fen.fens_of_string sample with
  | Error err ->
      failf "failed to derive FENs from fixture: %s" (Error.to_string_hum err)
  | Ok fens ->
      List.iteri fens ~f:(fun idx fen ->
          match Fen.normalize fen with
          | Ok _ -> ()
          | Error err ->
              failf "fixture FEN #%d failed normalization: %s" (idx + 1)
                (Error.to_string_hum err))

let suite =
  [
    test_case "normalizes valid initial position" `Quick
      test_valid_initial_position;
    test_case "accepts valid en passant square" `Quick test_valid_en_passant;
    test_case "rejects incorrect field count" `Quick test_invalid_field_count;
    test_case "rejects invalid rank description" `Quick
      test_invalid_rank_square_count;
    test_case "rejects position without kings" `Quick test_missing_king;
    test_case "rejects pawn on back rank" `Quick test_pawn_on_back_rank;
    test_case "rejects inconsistent en passant rank" `Quick
      test_invalid_en_passant_rank;
    test_case "rejects duplicate castling rights" `Quick
      test_duplicate_castling_rights;
    test_case "fixture FENs normalize" `Quick test_fixture_fens_normalize;
  ]
