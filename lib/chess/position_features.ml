open! Base

type theme =
  | Unknown
  | KingsideAttack
  | QueensideMajority
  | CentralBreak

let theme_of_tags tags =
  let downcased = List.map tags ~f:String.lowercase in
  if List.exists downcased ~f:(String.is_substring ~substring:"queenside majority") then
    QueensideMajority
  else if List.exists downcased ~f:(String.is_substring ~substring:"kingside attack") then
    KingsideAttack
  else if List.exists downcased ~f:(String.is_substring ~substring:"central break") then
    CentralBreak
  else
    Unknown

let to_payload_fragments = function
  | Unknown -> [ "theme", "unknown" ]
  | KingsideAttack -> [ "theme", "kingside_attack" ]
  | QueensideMajority -> [ "theme", "queenside_majority" ]
  | CentralBreak -> [ "theme", "central_break" ]
