open! Base

type player = {
  name : string;
  fide_id : string option;
  rating : int option;
}

let empty_player = { name = ""; fide_id = None; rating = None }

type t = {
  event : string option;
  site : string option;
  date : string option;
  round : string option;
  white : player;
  black : player;
  eco_code : string option;
  result : string option;
}

let empty =
  {
    event = None;
    site = None;
    date = None;
    round = None;
    white = empty_player;
    black = empty_player;
    eco_code = None;
    result = None;
  }
