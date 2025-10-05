open! Base

type rating_filter = {
  white_min : int option;
  black_max_delta : int option;
}

type request = {
  text : string;
}

type plan = {
  filters : (string * string) list;
  rating : rating_filter;
}

let analyse request =
  let lowered = String.lowercase request.text in
  let filters =
    [
      ( if String.is_substring lowered ~substring:"kings indian" then
          Some ("opening", "kings_indian_defense")
        else
          None
      );
      ( if String.is_substring lowered ~substring:"queenside majority" then
          Some ("theme", "queenside_majority")
        else
          None
      );
    ]
    |> List.filter_map ~f:Fn.id
  in
  let rating =
    let white_min =
      if String.is_substring lowered ~substring:"white" && String.is_substring lowered ~substring:"2500"
      then Some 2500
      else None
    in
    let black_delta =
      if String.is_substring lowered ~substring:"100 points lower" then Some 100 else None
    in
    { white_min; black_max_delta = black_delta }
  in
  { filters; rating }
