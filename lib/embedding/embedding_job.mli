(** Models embedding jobs and their status transitions in Postgres. *)

open! Base

(** Status of an embedding job. *)
type status = Pending | In_progress | Completed | Failed

val status_to_string : status -> string
[@@ocaml.doc "Serialise a status for storage/logging."]

val status_of_string : string -> status Or_error.t
[@@ocaml.doc "Parse a status coming from the database."]

type t = {
  id : int;
  fen : string;
  attempts : int;
  status : status;
  last_error : string option;
}
(** Representation of a job fetched from the database. *)

val create_pending : id:int -> fen:string -> t
[@@ocaml.doc "Build a new [Pending] job record."]

val mark_started : t -> t [@@ocaml.doc "Transition a job to [In_progress]."]

val mark_completed : t -> t [@@ocaml.doc "Transition a job to [Completed]."]

val mark_failed : t -> error:string -> t
[@@ocaml.doc "Transition a job to [Failed] with the supplied error message."]
