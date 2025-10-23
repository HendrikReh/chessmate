open! Base

val get : ?timeout:float -> string -> (int * string, string) Result.t
(** Perform a simple HTTP GET returning the status code and body. Errors are
    reported as sanitized strings ready for CLI output. [timeout] defaults to
    five seconds. *)
