open! Base

(* Placeholder implementation for PostgreSQL interactions.
   Persistence will be implemented once the database driver is integrated. *)

type t = string

let create conninfo =
  if String.is_empty conninfo then
    Or_error.error_string "Postgres connection string cannot be empty"
  else
    Or_error.return conninfo

let insert_game (_repo : t) ~metadata:_ ~pgn:_ ~moves =
  (* Simulate success by returning a fake game id and number of moves. *)
  Or_error.return (0, List.length moves)

let fetch_pending_jobs (_repo : t) ~limit:_ = Or_error.return []
let mark_job_started (_repo : t) ~job_id:_ = Or_error.return ()
let mark_job_completed (_repo : t) ~job_id:_ ~vector_id:_ = Or_error.return ()
let mark_job_failed (_repo : t) ~job_id:_ ~error:_ = Or_error.return ()
