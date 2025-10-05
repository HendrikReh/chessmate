open! Base

type status =
  | Pending
  | In_progress
  | Completed
  | Failed of string

let status_to_string = function
  | Pending -> "pending"
  | In_progress -> "in_progress"
  | Completed -> "completed"
  | Failed msg -> "failed:" ^ msg

type t = {
  id : int;
  fen : string;
  attempts : int;
  status : status;
}

let create_pending ~id ~fen = { id; fen; attempts = 0; status = Pending }

let mark_started job = { job with status = In_progress; attempts = job.attempts + 1 }

let mark_completed job = { job with status = Completed }

let mark_failed job ~error = { job with status = Failed error }
