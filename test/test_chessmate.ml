open! Base

let test_pgn_parser_placeholder () =
  match Chessmate.Pgn_parser.parse "" with
  | Ok _ -> Alcotest.fail "expected placeholder error"
  | Error _ -> ()

let suite =
  [
    ( "pgn parser placeholder"
    , `Quick
    , test_pgn_parser_placeholder
    );
  ]

let () = Alcotest.run "chessmate" [ "core", suite ]
