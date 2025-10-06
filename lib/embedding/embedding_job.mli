open! Base

(** Status of an embedding job. *)
type status =
  | Pending
  | In_progress
  | Completed
  | Failed

val status_to_string : status -> string
val status_of_string : string -> status Or_error.t

(** Representation of a job fetched from the database. *)
type t = {
  id : int;
  fen : string;
  attempts : int;
  status : status;
  last_error : string option;
}

val create_pending : id:int -> fen:string -> t
val mark_started : t -> t
val mark_completed : t -> t
val mark_failed : t -> error:string -> t
