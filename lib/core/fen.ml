open! Base

type t = string

let normalize fen =
  if String.is_empty fen then
    Or_error.error_string "FEN must be non-empty"
  else
    Ok fen

let hash fen =
  Stdlib.Digest.(string fen |> to_hex)
