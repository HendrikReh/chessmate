open! Base

type job = {
  fen : string;
  metadata : (string * string) list;
}

type t = job Queue.t

let create () = Queue.create ()

let enqueue t job =
  Queue.enqueue t job;
  Ok ()

let dequeue_batch t limit =
  if limit <= 0 then Or_error.error_string "limit must be positive"
  else
    let rec loop acc remaining =
      if remaining = 0 || Queue.is_empty t then List.rev acc
      else
        let next = Queue.dequeue_exn t in
        loop (next :: acc) (remaining - 1)
    in
    Ok (loop [] limit)
