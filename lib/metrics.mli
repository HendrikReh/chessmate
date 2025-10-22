open! Base

module Registry : sig
  type t = Prometheus.CollectorRegistry.t

  val current : unit -> t
  (** Active registry used for newly created metrics. *)

  val use : t -> unit
  (** Switch the active registry. Existing metric handles become invalid and
      should be recreated by callers. *)

  val use_default : unit -> unit
  (** Reset the active registry to the library default. *)

  val create : unit -> t
  (** Allocate a fresh registry, useful for tests. *)

  val collect : ?registry:t -> unit -> string Lwt.t
  (** Collect all registered metrics from [registry] (defaults to {!current})
      and render them in Prometheus text exposition format. *)
end

module Counter : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val inc : ?label_values:string list -> ?amount:float -> t -> unit Or_error.t
  val inc_one : ?label_values:string list -> t -> unit Or_error.t
end

module Gauge : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val set : ?label_values:string list -> float -> t -> unit Or_error.t
  val inc : ?label_values:string list -> ?amount:float -> t -> unit Or_error.t
  val dec : ?label_values:string list -> ?amount:float -> t -> unit Or_error.t
end

module Summary : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val observe : ?label_values:string list -> float -> t -> unit Or_error.t
end

module Histogram : sig
  type t

  val create :
    ?registry:Registry.t ->
    ?namespace:string ->
    ?subsystem:string ->
    ?label_names:string list ->
    help:string ->
    string ->
    t Or_error.t

  val observe : ?label_values:string list -> float -> t -> unit Or_error.t
end
