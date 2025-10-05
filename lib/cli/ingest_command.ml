open! Base
open Stdio

let run path =
  if not (Stdlib.Sys.file_exists path) then
    Or_error.errorf "PGN file %s does not exist" path
  else
    let contents = In_channel.read_all path in
    match Pgn_parser.parse contents with
    | Error err -> Or_error.errorf "Failed to parse PGN: %s" (Error.to_string_hum err)
    | Ok parsed ->
        let header_count = List.length parsed.headers in
        let move_count = List.length parsed.moves in
        printf "Parsed PGN with %d headers and %d moves\n" header_count move_count;
        Or_error.return ()
