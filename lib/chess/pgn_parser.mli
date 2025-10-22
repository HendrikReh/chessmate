(** Streaming PGN parser that extracts headers, moves, and metadata. *)

open! Base

val default_valid_results : string list
(** Valid tokens permitted in the [Result] tag. *)

type move = { san : string; turn : int; ply : int }

type t = { headers : (string * string) list; moves : move list }
(** Parsed PGN artifact with metadata headers and SAN moves. *)

val parse : string -> t Or_error.t
(** [parse raw_pgn] returns headers and moves extracted from a PGN string. *)

val parse_file : string -> t Or_error.t
(** [parse_file path] reads [path] and delegates to [parse]. *)

val fold_games :
  ?on_error:('a -> index:int -> raw:string -> Error.t -> 'a Or_error.t) ->
  string ->
  init:'a ->
  f:('a -> index:int -> raw:string -> t -> 'a Or_error.t) ->
  'a Or_error.t
(** Iterate through every game contained in a PGN blob without loading the
    entire result set eagerly. The folding function receives the 1-based
    [index], the original [raw] PGN text for that game, and the parsed
    representation. When [on_error] is supplied, parsing failures are reported
    to the handler and iteration continues; otherwise parsing failures abort the
    fold. *)

val stream_games :
  ?on_error:(index:int -> raw:string -> Error.t -> unit Lwt.t) ->
  string ->
  f:(index:int -> raw:string -> t -> unit Lwt.t) ->
  unit Lwt.t
(** Iterate asynchronously over PGN games, invoking [f] for each successfully
    parsed game. Errors are routed through [on_error] (default: raise). Parsing
    happens sequentially; consumer functions decide how to schedule work. *)

val parse_games : string -> t list Or_error.t
(** [parse_games raw_pgn] parses all games contained in [raw_pgn]. *)

val parse_file_games : string -> t list Or_error.t
(** [parse_file_games path] reads [path] and delegates to [parse_games]. *)

val ply_count : t -> int
val white_name : t -> string option
val black_name : t -> string option
val white_rating : t -> int option
val black_rating : t -> int option
val event : t -> string option
val site : t -> string option
val round : t -> string option
val result : t -> string option
val event_date : t -> string option
val white_move : t -> int -> move option
val black_move : t -> int -> move option
val tag_value : t -> string -> string option
