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
        let metadata = Game_metadata.of_headers parsed.headers in
        Cli_common.with_db_url (fun url ->
            match Repo_postgres.create url with
            | Error err -> Error err
            | Ok repo ->
                (match Repo_postgres.insert_game repo ~metadata ~pgn:contents ~moves:parsed.moves with
                | Ok (game_id, position_count) ->
                    printf "Stored game %d with %d positions\n" game_id position_count;
                    Or_error.return ()
                | Error err -> Error err))
