open! Base

let run query =
  if String.is_empty query then Or_error.error_string "query cannot be empty"
  else Or_error.error_string "Search command not implemented yet"
