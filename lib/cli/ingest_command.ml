open! Base

let run path =
  if not (Stdlib.Sys.file_exists path) then
    Or_error.errorf "PGN file %s does not exist" path
  else
    Or_error.error_string "Ingest command not implemented yet"
