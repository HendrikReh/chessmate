open! Base
open Alcotest
open Chessmate

let empty_rating =
  { Query_intent.white_min = None; black_min = None; max_rating_delta = None }

let test_whitelist_rejects_unknown_fields () =
  let filters =
    [ { Query_intent.field = "opening'; DROP TABLE games; --"; value = "sicilian" } ]
  in
  let conditions, params, _ =
    Repo_postgres.Private.build_conditions ~filters ~rating:empty_rating
  in
  check int "ignored unsupported field" 0 (List.length conditions);
  check (list (option string)) "no params recorded" [] params

let test_opening_filter_parameterized () =
  let filters =
    [ { Query_intent.field = "opening"; value = " Najdorf'; OR 1=1 --" } ]
  in
  let conditions, params, _ =
    Repo_postgres.Private.build_conditions ~filters ~rating:empty_rating
  in
  match conditions, params with
  | [ clause ], [ Some param ] ->
      check bool "no raw value in SQL"
        false
        (String.is_substring clause ~substring:"OR 1=1");
      check string "normalized param"
        "najdorf'; or 1=1 --"
        param
  | _ -> fail "unexpected condition or params layout"

let test_case_insensitive_whitelist_fields () =
  let filters =
    [ { Query_intent.field = "WHITE"; value = "  Kasparov  " }
    ; { Query_intent.field = "event"; value = "Linares" }
    ]
  in
  let conditions, params, _ =
    Repo_postgres.Private.build_conditions ~filters ~rating:empty_rating
  in
  check int "two conditions" 2 (List.length conditions);
  check bool "white filter uses LOWER"
    true
    (List.exists conditions ~f:(String.is_substring ~substring:"LOWER(w.name)"));
  let params = List.map params ~f:(Option.value ~default:"<none>") in
  check (list string) "params normalized"
    [ "kasparov"; "linares" ]
    params

let suite =
  [ "rejects unsupported fields", `Quick, test_whitelist_rejects_unknown_fields
  ; "opening filter parameterized", `Quick, test_opening_filter_parameterized
  ; "case-insensitive filters", `Quick, test_case_insensitive_whitelist_fields
  ]
