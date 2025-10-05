open! Base

let with_db_url f =
  match Sys.getenv "DATABASE_URL" with
  | None -> Or_error.error_string "DATABASE_URL not set"
  | Some url -> f url
