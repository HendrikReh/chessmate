open! Base

type violation = { limit : int; actual : int }

val error : limit:int -> actual:int -> Base.Error.t
val enforce : limit:int -> actual:int -> unit Or_error.t
